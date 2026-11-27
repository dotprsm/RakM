CC = clang
CFLAGS = -Wall -Wextra -O2 -fobjc-arc
LDFLAGS = -framework Foundation

TARGET = rakm
SRCS = src/RakM.m

all: $(TARGET)

$(TARGET): $(SRCS) src/RakM.h
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
