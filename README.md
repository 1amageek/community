# Community

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2026+-blue.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A distributed actor-based member management system that enables communication and collaboration across multiple terminal sessions over the network.

Built on Swift's Distributed Actors and gRPC, allowing members on different machines to send and receive messages.

## Features

| | Feature | Description |
|---|---------|-------------|
| 🌐 | **Distributed Actors** | Built on Swift's native distributed actor system for type-safe remote communication |
| 🔌 | **gRPC Transport** | High-performance networking via gRPC protocol |
| 💻 | **PTY Management** | Full pseudo-terminal support for interactive shell sessions |
| 🔍 | **Member Discovery** | Automatic discovery and listing of members across the network |
| 📨 | **Message Passing** | Send messages directly to any member's terminal |
| ⚡ | **Async/Await** | Modern Swift concurrency throughout |

## Installation

```bash
git clone https://github.com/1amageek/community.git
cd community
swift build
```

## Quick Start

```bash
# Terminal 1: Join as alice
swift run mm join -n alice -p 50051

# Terminal 2: Join as bob
swift run mm join -n bob -p 50052

# Terminal 3: Send message from anywhere
swift run mm tell alice "Hello from the network!" -p 50051
```

## Usage

### Join the Community

```bash
# Join with default shell (/bin/bash)
swift run mm join

# Join with a custom command
swift run mm join /bin/zsh

# Specify name and port
swift run mm join /bin/bash -n alice -p 50051
```

This starts a PTY (pseudo-terminal) running your command. Press `Ctrl+C` to exit.

### Send a Message to a Member

```bash
# Send message to a member on localhost
swift run mm tell alice "Hello, Alice!"

# Send message to a member on a remote host
swift run mm tell alice "Hello!" -h 192.168.1.100 -p 50051
```

Messages are sent as input to the target member's PTY.

### List Members

```bash
# List members on localhost
swift run mm list

# List members on a remote host
swift run mm list -h 192.168.1.100 -p 50051
```

## Commands

| Command | Description |
|---------|-------------|
| `mm join [command]` | Join the community |
| `mm tell <name> <message>` | Send a message to a member |
| `mm list` | List all members |
| `mm leave` | Leave the community (use Ctrl+C) |

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-n, --name` | Member name | TTY name or hostname |
| `-h, --host` | Target host | 127.0.0.1 |
| `-p, --port` | Target port | 50051 |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Community System                      │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐    gRPC    ┌──────────────┐           │
│  │   Member A   │◄──────────►│   Member B   │           │
│  │  (Terminal)  │            │  (Terminal)  │           │
│  └──────┬───────┘            └──────┬───────┘           │
│         │                           │                    │
│         ▼                           ▼                    │
│  ┌──────────────┐            ┌──────────────┐           │
│  │     PTY      │            │     PTY      │           │
│  │  /bin/bash   │            │  /bin/zsh    │           │
│  └──────────────┘            └──────────────┘           │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Components

| | Component | Description |
|---|-----------|-------------|
| 🎭 | **CommunitySystem** | Distributed Actor System implementation. Manages local and remote actors |
| 👤 | **Member** | Distributed actor representing each participant. Owns a PTY and receives messages |
| 🔎 | **SystemActor** | System actor providing member discovery and listing |
| 🖥️ | **PTY** | POSIX pseudo-terminal management. Controls process I/O |

## Dependencies

- [swift-peer](https://github.com/1amageek/swift-peer) - gRPC transport and distributed system infrastructure
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - CLI parser

## License

MIT License
