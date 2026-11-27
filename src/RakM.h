#import <Foundation/Foundation.h>

@interface RakMStats : NSObject

@property (nonatomic, assign) NSUInteger sent;
@property (nonatomic, assign) NSUInteger received;
@property (nonatomic, assign) double lastRttMs;
@property (nonatomic, assign) double minRttMs;
@property (nonatomic, assign) double maxRttMs;
@property (nonatomic, assign) double totalRttMs;
@property (nonatomic, assign) double lastJitterMs;
@property (nonatomic, assign) double prevRttMs;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *serverGuid;
@property (nonatomic, copy) NSString *rawPayload;
@property (nonatomic, copy) NSString *edition;
@property (nonatomic, copy) NSString *motd;
@property (nonatomic, copy) NSString *protocolVersion;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy) NSString *playerCount;
@property (nonatomic, copy) NSString *maxPlayers;
@property (nonatomic, copy) NSString *gamemode;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *history;

- (void)recordSuccessWithRtt:(double)rttMs;
- (void)recordTimeout;
- (void)reset;
- (double)averageRttMs;
- (double)lossPercent;

@end

@interface RakMMonitor : NSObject

@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, assign, readonly) NSUInteger intervalMs;
@property (nonatomic, strong, readonly) RakMStats *stats;

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port intervalMs:(NSUInteger)intervalMs;
- (int)run;

@end
