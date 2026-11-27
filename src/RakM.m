#import "RakM.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static struct termios origTermios;
static BOOL termiosSaved = NO;

static const uint8_t RAK_MAGIC[16] = {
    0x00, 0xff, 0xff, 0x00,
    0xfe, 0xfe, 0xfe, 0xfe,
    0xfd, 0xfd, 0xfd, 0xfd,
    0x12, 0x34, 0x56, 0x78
};

static void handleSignal(int sig) {
    (void)sig;
    running = 0;
}

static void restoreTerminal(void) {
    if (termiosSaved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &origTermios);
        termiosSaved = NO;
    }
    printf("\033[?25h\033[0m\n");
    fflush(stdout);
}

static void setupTerminal(void) {
    if (isatty(STDIN_FILENO)) {
        if (tcgetattr(STDIN_FILENO, &origTermios) == 0) {
            termiosSaved = YES;
            struct termios raw = origTermios;
            raw.c_lflag &= ~(ICANON | ECHO);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 0;
            tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        }
        printf("\033[?25l");
        fflush(stdout);
    }
}

static uint64_t currentTimeMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000ULL + (uint64_t)tv.tv_usec / 1000ULL;
}

static void writeUInt64BE(uint8_t *buf, uint64_t val) {
    for (int i = 0; i < 8; i++) {
        buf[i] = (uint8_t)((val >> ((7 - i) * 8)) & 0xff);
    }
}

static uint64_t readUInt64BE(const uint8_t *buf) {
    uint64_t val = 0;
    for (int i = 0; i < 8; i++) {
        val = (val << 8) | buf[i];
    }
    return val;
}

static uint16_t readUInt16BE(const uint8_t *buf) {
    return (uint16_t)((buf[0] << 8) | buf[1]);
}

@implementation RakMStats

- (instancetype)init {
    self = [super init];
    if (self) {
        _history = [NSMutableArray array];
        [self reset];
    }
    return self;
}

- (void)reset {
    _sent = 0;
    _received = 0;
    _lastRttMs = 0.0;
    _minRttMs = 0.0;
    _maxRttMs = 0.0;
    _totalRttMs = 0.0;
    _lastJitterMs = 0.0;
    _prevRttMs = -1.0;
    _status = @"WAITING";
    _serverGuid = @"-";
    _rawPayload = @"";
    _edition = @"-";
    _motd = @"-";
    _protocolVersion = @"-";
    _gameVersion = @"-";
    _playerCount = @"-";
    _maxPlayers = @"-";
    _gamemode = @"-";
    [_history removeAllObjects];
}

- (void)recordSuccessWithRtt:(double)rttMs {
    _received++;
    _lastRttMs = rttMs;
    _totalRttMs += rttMs;
    if (_received == 1 || rttMs < _minRttMs) {
        _minRttMs = rttMs;
    }
    if (rttMs > _maxRttMs) {
        _maxRttMs = rttMs;
    }
    if (_prevRttMs >= 0.0) {
        double diff = rttMs - _prevRttMs;
        if (diff < 0) diff = -diff;
        _lastJitterMs = diff;
    }
    _prevRttMs = rttMs;
    _status = @"ONLINE";
    [_history addObject:@(rttMs)];
    if (_history.count > 24) {
        [_history removeObjectAtIndex:0];
    }
}

- (void)recordTimeout {
    _status = @"TIMEOUT";
    [_history addObject:@(-1.0)];
    if (_history.count > 24) {
        [_history removeObjectAtIndex:0];
    }
}

- (double)averageRttMs {
    if (_received == 0) return 0.0;
    return _totalRttMs / (double)_received;
}

- (double)lossPercent {
    if (_sent == 0) return 0.0;
    NSUInteger lost = _sent - _received;
    return ((double)lost / (double)_sent) * 100.0;
}

@end

@implementation RakMMonitor {
    int _sock;
    struct sockaddr_storage _addr;
    socklen_t _addrLen;
    NSString *_resolvedIP;
    uint64_t _clientGuid;
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port intervalMs:(NSUInteger)intervalMs {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _intervalMs = intervalMs < 200 ? 200 : intervalMs;
        _stats = [[RakMStats alloc] init];
        _sock = -1;
        _clientGuid = ((uint64_t)arc4random() << 32) | arc4random();
    }
    return self;
}

- (void)dealloc {
    if (_sock >= 0) {
        close(_sock);
        _sock = -1;
    }
}

- (BOOL)resolveAndOpenSocket {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%u", _port);

    struct addrinfo *res = NULL;
    int err = getaddrinfo([_host UTF8String], portStr, &hints, &res);
    if (err != 0 || !res) {
        fprintf(stderr, "Failed to resolve %s:%u (%s)\n", [_host UTF8String], _port, gai_strerror(err));
        return NO;
    }

    for (struct addrinfo *p = res; p != NULL; p = p->ai_next) {
        int s = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (s < 0) continue;

        _sock = s;
        memcpy(&_addr, p->ai_addr, p->ai_addrlen);
        _addrLen = (socklen_t)p->ai_addrlen;

        char ipBuf[INET6_ADDRSTRLEN] = {0};
        if (p->ai_family == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *)p->ai_addr;
            inet_ntop(AF_INET, &sin->sin_addr, ipBuf, sizeof(ipBuf));
        } else if (p->ai_family == AF_INET6) {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)p->ai_addr;
            inet_ntop(AF_INET6, &sin6->sin6_addr, ipBuf, sizeof(ipBuf));
        }
        _resolvedIP = [NSString stringWithUTF8String:ipBuf];
        break;
    }

    freeaddrinfo(res);
    if (_sock < 0) {
        fprintf(stderr, "Unable to open UDP socket: %s\n", strerror(errno));
        return NO;
    }
    return YES;
}

- (void)sendPingWithTimestamp:(uint64_t)ts {
    uint8_t pkt[33];
    pkt[0] = 0x01;
    writeUInt64BE(pkt + 1, ts);
    memcpy(pkt + 9, RAK_MAGIC, 16);
    writeUInt64BE(pkt + 25, _clientGuid);

    _stats.sent++;
    sendto(_sock, pkt, sizeof(pkt), 0, (struct sockaddr *)&_addr, _addrLen);
}

- (void)parsePongPacket:(const uint8_t *)buf length:(ssize_t)len receivedAt:(uint64_t)nowMs {
    if (len < 35 || buf[0] != 0x1c) {
        return;
    }
    if (memcmp(buf + 17, RAK_MAGIC, 16) != 0) {
        return;
    }

    uint64_t sentTs = readUInt64BE(buf + 1);
    double rtt = (nowMs >= sentTs) ? (double)(nowMs - sentTs) : 0.0;
    [_stats recordSuccessWithRtt:rtt];

    uint64_t guid = readUInt64BE(buf + 9);
    _stats.serverGuid = [NSString stringWithFormat:@"%llu", guid];

    uint16_t strLen = readUInt16BE(buf + 33);
    if (35 + strLen <= len && strLen > 0) {
        NSData *data = [NSData dataWithBytes:(buf + 35) length:strLen];
        NSString *payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!payload) {
            payload = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        if (payload) {
            _stats.rawPayload = payload;
            NSArray<NSString *> *parts = [payload componentsSeparatedByString:@";"];
            if (parts.count >= 6) {
                _stats.edition = parts[0];
                _stats.motd = parts[1];
                _stats.protocolVersion = parts[2];
                _stats.gameVersion = parts[3];
                _stats.playerCount = parts[4];
                _stats.maxPlayers = parts[5];
                _stats.gamemode = parts.count >= 9 ? parts[8] : @"-";
            }
        }
    }
}

- (NSString *)sparkline {
    if (_stats.history.count == 0) return @"-";
    const char *bars[] = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"};
    double maxVal = 1.0;
    for (NSNumber *n in _stats.history) {
        if (n.doubleValue > maxVal) maxVal = n.doubleValue;
    }
    NSMutableString *out = [NSMutableString string];
    for (NSNumber *n in _stats.history) {
        double v = n.doubleValue;
        if (v < 0) {
            [out appendString:@"\033[31mx\033[0m"];
        } else {
            int idx = (int)((v / maxVal) * 7.0);
            if (idx < 0) idx = 0;
            if (idx > 7) idx = 7;
            [out appendFormat:@"\033[32m%s\033[0m", bars[idx]];
        }
    }
    return out;
}

- (void)render {
    const char *statusColor = "\033[33m";
    if ([_stats.status isEqualToString:@"ONLINE"]) {
        statusColor = "\033[32m";
    } else if ([_stats.status isEqualToString:@"TIMEOUT"]) {
        statusColor = "\033[31m";
    }

    printf("\033[2J\033[H");
    printf("\033[1;36mRakM\033[0m - RakNet Monitor\n");
    printf("Target:   %s:%u (%s)\n", [_host UTF8String], _port, [_resolvedIP UTF8String]);
    printf("Status:   %s%s\033[0m\n", statusColor, [_stats.status UTF8String]);
    printf("Interval: %lu ms\n", (unsigned long)_intervalMs);
    printf("\n");
    printf("Packets:  sent %lu | recv %lu | loss %.1f%%\n",
           (unsigned long)_stats.sent,
           (unsigned long)_stats.received,
           [_stats lossPercent]);
    printf("Latency:  last %.1f ms | min %.1f ms | avg %.1f ms | max %.1f ms | jitter %.1f ms\n",
           _stats.lastRttMs,
           _stats.minRttMs,
           [_stats averageRttMs],
           _stats.maxRttMs,
           _stats.lastJitterMs);
    printf("History:  %s\n", [[self sparkline] UTF8String]);
    printf("\n");
    printf("Server GUID: %s\n", [_stats.serverGuid UTF8String]);
    if (![_stats.motd isEqualToString:@"-"]) {
        printf("Edition:     %s\n", [_stats.edition UTF8String]);
        printf("MOTD:        %s\n", [_stats.motd UTF8String]);
        printf("Version:     %s (protocol %s)\n", [_stats.gameVersion UTF8String], [_stats.protocolVersion UTF8String]);
        printf("Players:     %s / %s\n", [_stats.playerCount UTF8String], [_stats.maxPlayers UTF8String]);
        printf("Gamemode:    %s\n", [_stats.gamemode UTF8String]);
    } else if (_stats.rawPayload.length > 0) {
        printf("Payload:     %s\n", [_stats.rawPayload UTF8String]);
    }
    printf("\n\033[90m[q] quit  [r] reset stats\033[0m\n");
    fflush(stdout);
}

- (int)run {
    if (![self resolveAndOpenSocket]) {
        return 1;
    }

    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);
    setupTerminal();

    while (running) {
        uint64_t pingTs = currentTimeMs();
        [self sendPingWithTimestamp:pingTs];

        BOOL gotPong = NO;
        uint64_t deadline = pingTs + _intervalMs;

        while (running) {
            uint64_t now = currentTimeMs();
            if (now >= deadline) break;

            int timeoutMs = (int)(deadline - now);
            struct pollfd fds[2];
            fds[0].fd = _sock;
            fds[0].events = POLLIN;
            fds[0].revents = 0;

            nfds_t nfds = 1;
            if (isatty(STDIN_FILENO)) {
                fds[1].fd = STDIN_FILENO;
                fds[1].events = POLLIN;
                fds[1].revents = 0;
                nfds = 2;
            }

            int ret = poll(fds, nfds, timeoutMs);
            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (ret == 0) {
                break;
            }

            if (fds[0].revents & POLLIN) {
                uint8_t buf[2048];
                ssize_t n = recvfrom(_sock, buf, sizeof(buf), 0, NULL, NULL);
                if (n > 0) {
                    [self parsePongPacket:buf length:n receivedAt:currentTimeMs()];
                    gotPong = YES;
                    [self render];
                }
            }

            if (nfds == 2 && (fds[1].revents & POLLIN)) {
                char ch = 0;
                if (read(STDIN_FILENO, &ch, 1) == 1) {
                    if (ch == 'q' || ch == 'Q') {
                        running = 0;
                        break;
                    } else if (ch == 'r' || ch == 'R') {
                        [_stats reset];
                        [self render];
                    }
                }
            }
        }

        if (!gotPong && running) {
            [_stats recordTimeout];
            [self render];
        }
    }

    restoreTerminal();
    return 0;
}

@end

static void printUsage(const char *prog) {
    printf("Usage: %s <host> [port] [interval_ms]\n", prog);
    printf("  host         Target hostname or IP address\n");
    printf("  port         Target UDP port (default: 19132)\n");
    printf("  interval_ms  Ping interval in milliseconds (default: 1000)\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
            printUsage(argv[0]);
            return argc < 2 ? 1 : 0;
        }

        NSString *host = [NSString stringWithUTF8String:argv[1]];
        uint16_t port = 19132;
        NSUInteger intervalMs = 1000;

        if (argc >= 3) {
            long p = strtol(argv[2], NULL, 10);
            if (p <= 0 || p > 65535) {
                fprintf(stderr, "Invalid port: %s\n", argv[2]);
                return 1;
            }
            port = (uint16_t)p;
        }

        if (argc >= 4) {
            long iv = strtol(argv[3], NULL, 10);
            if (iv <= 0) {
                fprintf(stderr, "Invalid interval: %s\n", argv[3]);
                return 1;
            }
            intervalMs = (NSUInteger)iv;
        }

        RakMMonitor *monitor = [[RakMMonitor alloc] initWithHost:host port:port intervalMs:intervalMs];
        return [monitor run];
    }
}
