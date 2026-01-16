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

### Using Mint (Recommended)

```bash
mint install 1amageek/community@main
```

### From Source

```bash
git clone https://github.com/1amageek/community.git
cd community
swift build -c release
cp .build/release/mm /usr/local/bin/
```

## Quick Start

### Same Device (Automatic Server Sharing)

```bash
# Terminal 1: Start first member (binds to port 50051)
mm join  # Uses $SHELL (e.g., zsh) by default

# Terminal 2: Start second member (auto-connects to existing server)
mm join

# Terminal 3: List all members
mm list
# Output (* marks yourself):
#   NAME        PEER                        COMMAND   PROCESS   CWD
# ----------------------------------------------------------------------------------------------------
# * ttys001     ttys001@127.0.0.1:50051     zsh       -         ~/Desktop/community
#   ttys002     ttys002@127.0.0.1:52341     zsh       vim       ~/projects
```

### Cross-Network (Manual Connection)

```bash
# Machine A (192.168.1.100)
mm join --name alice

# Machine B
mm join --name bob --peer alice@192.168.1.100:50051

# From Machine B
mm tell alice "Hello!"
```

## Usage

### Join the Community

```bash
# Join with default shell ($SHELL)
mm join

# Join with a specific shell/command
mm join zsh
mm join bash
mm join claude

# Specify custom name
mm join --name alice

# Connect to a peer on another machine
mm join --name bob --peer alice@192.168.1.100:50051

# Use a specific port (default: 50051, auto-fallback if busy)
mm join --port 50052
```

**Automatic Port Handling:**
- First instance binds to port 50051
- Subsequent instances auto-detect busy port and use a random port
- Automatically connects to existing local server

Press `Ctrl+C` to exit.

### Send a Message to a Member

```bash
# Send message to a member (connects to default port 50051)
mm tell alice "Hello, Alice!"

# Send message via a specific host
mm tell alice "Hello!" --host 192.168.1.100 --port 50051
```

Messages are sent as input to the target member's PTY.

### List Members

```bash
# List all members (local + remote peers)
mm list

# List members via a specific host
mm list --host 192.168.1.100 --port 50051
```

The list shows all members known to the connected peer, including members from other connected peers.

### Disconnect Peers / Kill Processes

```bash
# Disconnect a specific peer
mm kill codex@127.0.0.1:50051

# Disconnect multiple peers at once
mm kill alice@127.0.0.1:50051 bob@192.168.1.100:50051

# Kill all mm join processes (SIGTERM)
mm kill --all

# Force kill all mm join processes (SIGKILL)
mm kill --all -f
```

## Commands

| Command | Description |
|---------|-------------|
| `mm join [command]` | Join the community with a PTY (uses $SHELL if command omitted) |
| `mm tell <name> <message>` | Send a message to a member's PTY |
| `mm list` | List all members (local + remote) |
| `mm kill <peer-id>...` | Disconnect specific peers from the mesh |
| `mm kill --all` | Kill all mm join processes |
| `mm leave <name>` | Leave the community (shows usage hint) |

**Note:** `mm` without arguments defaults to `mm list`.

### Join Options

| Option | Description | Default |
|--------|-------------|---------|
| `--name, -n` | Member name | TTY name (e.g., ttys001) |
| `--host` | Host address to bind | 127.0.0.1 |
| `--port, -p` | Port to listen on | 50051 (auto-fallback if busy) |
| `--peer` | Peer(s) to connect to (format: name@host:port, can specify multiple) | - |
| `--no-discovery` | Disable mDNS advertising | false |

### Kill Options

| Option | Description | Default |
|--------|-------------|---------|
| `<peer-id>...` | Peer ID(s) to disconnect (format: name@host:port) | - |
| `--all` | Kill all mm join processes | false |
| `-f, --force` | Force kill with SIGKILL (instead of SIGTERM) | false |

### List/Tell Options

| Option | Description | Default |
|--------|-------------|---------|
| `--host` | Target host | 127.0.0.1 |
| `--port, -p` | Target port | 50051 |

## Architecture

### P2P Mesh Network

```
Terminal 1 (Alice)                    Terminal 2 (Bob)
┌─────────────────────────────┐      ┌─────────────────────────────┐
│     CommunitySystem         │      │     CommunitySystem         │
│  ┌───────────────────────┐  │      │  ┌───────────────────────┐  │
│  │ PeerNode (:50051)     │◄─┼──────┼─►│ PeerNode (:52341)     │  │
│  └───────────────────────┘  │      │  └───────────────────────┘  │
│  ┌───────────────────────┐  │      │  ┌───────────────────────┐  │
│  │ Member: alice         │  │      │  │ Member: bob           │  │
│  │ PTY: /bin/zsh         │  │      │  │ PTY: /bin/zsh         │  │
│  └───────────────────────┘  │      │  └───────────────────────┘  │
└─────────────────────────────┘      └─────────────────────────────┘
         │                                      │
         ▼                                      ▼
    mm list shows:                         mm list shows:
    - alice (local)                        - bob (local)
    - bob (remote)                         - alice (remote)
```

### Connection Model

| Scenario | Behavior |
|----------|----------|
| Same device | First member binds 50051, others auto-connect |
| Same network | mDNS discovery (coming soon) |
| Cross network | Manual `--peer` connection |

### Components

| Component | Description |
|-----------|-------------|
| **CommunitySystem** | Distributed Actor System implementation. Routes messages to local/remote actors |
| **Member** | Distributed actor with PTY. Receives messages via `tell()` |
| **SystemActor** | Well-known actor (UUID: 00000000-...-000001) for member discovery |
| **PeerNode** | P2P networking abstraction from swift-peer |
| **PTY** | POSIX pseudo-terminal for interactive shell sessions |

### Member Exchange Protocol

When peers connect, they exchange member information:

1. Peer A connects to Peer B
2. Both query each other's `SystemActor.listMembers()`
3. Remote members are stored locally
4. `mm list` returns both local and remote members

## Dependencies

- [swift-peer](https://github.com/1amageek/swift-peer) - P2P networking via PeerNode abstraction
- [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime) - Distributed Actor codec and registry
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - CLI parser

## Requirements

- Swift 6.2+
- macOS 26+

## License

MIT License
