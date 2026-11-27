# RakM

Simple RakNet monitor for macOS

## Build

```sh
make
```

## Usage

```sh
./rakm <host> [port] [interval_ms]
```

- `host`: Target hostname or IP address
- `port`: Target UDP port (defaults to `19132`)
- `interval_ms`: Ping interval in ms (defaults to: `1000`)

### Keybinds

- `q`: Quit
- `r`: Reset statistics
