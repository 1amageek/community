# community

pty を持つ分散アクターシステム

## 目的

異なるマシン・異なるネットワーク上で動作するプロセス同士が、シンプルなコマンドでメッセージをやり取りできるようにする。

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Machine A   │     │  Machine B   │     │  Machine C   │
│              │     │              │     │              │
│    alice ←───┼─────┼──── bob ←────┼─────┼─── charlie   │
│              │     │              │     │              │
└──────────────┘     └──────────────┘     └──────────────┘

$ mm tell bob "こんにちは"
→ どこにいても届く
```

## 設計原則

### プロトコルベースのプラガブル設計

本システムは **プロトコルベースのプラガブル設計** を採用している。
distributed actor が `DistributedActorSystem` プロトコルで実装非依存なように、
Discovery と Transport もプロトコルで抽象化し、実装を交換可能にする。

```
┌─────────────────────────────────────────────────────────────────┐
│  Application Layer                                              │
│  - mm CLI コマンド                                               │
│  - Member distributed actor                                     │
│  - tell(), getName() などのビジネスロジック                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Distributed Actor Layer                                        │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  Swift Distributed Actor                                   │ │
│  │  - DistributedActorSystem プロトコル                        │ │
│  │  - remoteCall() / remoteCallVoid() で通信を抽象化           │ │
│  │  - ActorID でアクターを一意に識別                           │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  swift-peer                                                │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  Transport Protocol (データ転送の抽象化)                    │ │
│  │  - send(to:data:timeout:) async throws -> Data            │ │
│  │                                                           │ │
│  │  ┌─────────────┬─────────────┬─────────────────────┐     │ │
│  │  │GRPCTransport│BLETransport │WebSocketTransport   │     │ │
│  │  │  (実装)     │   (実装)    │     (実装)          │     │ │
│  │  └─────────────┴─────────────┴─────────────────────┘     │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │  PeerDiscovery Protocol (ピア発見の抽象化)                  │ │
│  │  - discover() / advertise() / stopAdvertising()           │ │
│  │                                                           │ │
│  │  ┌─────────────┬─────────────┬─────────────────────┐     │ │
│  │  │LocalNetwork │NearbyDiscov │BootstrapDiscovery   │     │ │
│  │  │  (mDNS)     │   (BLE)     │   (Server)          │     │ │
│  │  └─────────────┴─────────────┴─────────────────────┘     │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Discovery と Transport の対応関係

Discovery と Transport は同じデバイス能力に依存するため、swift-peer で両方を管理：

| デバイス能力 | Discovery 実装 | Transport 実装 |
|------------|----------------|----------------|
| WiFi/Ethernet | LocalNetworkDiscovery (mDNS) | GRPCTransport, WebSocketTransport |
| Bluetooth | NearbyDiscovery (BLE) | BLETransport |
| Internet | BootstrapDiscovery | WebSocketTransport |

### 各レイヤーの責務

| レイヤー | 責務 | 質問に答える |
|---------|------|-------------|
| Distributed Actor | リモートメソッド呼び出しの抽象化 | 「どう呼び出すか？」 |
| Transport (Protocol) | データ転送の抽象化 | 「どう送るか？」 |
| PeerDiscovery (Protocol) | ピア発見の抽象化 | 「誰がいるか？」 |

### なぜプロトコルベース設計が重要か

1. **テスト容易性**: Mock Transport/Discovery を使用して統合テストが可能
2. **柔軟性**: 環境に応じて最適な Transport と Discovery を選択可能
3. **将来性**: 新しい通信プロトコル（BLE, WebSocket 等）への対応が容易
4. **一貫性**: distributed actor と同じプラガブルなパターン

## コマンド

```bash
mm                           # 参加中のメンバー一覧 (who風)
mm join <command>            # メンバーとして参加（名前はターミナル名）
mm join <command> -n <name>  # 名前を指定して参加
mm tell <name> "text"        # メンバーにメッセージを送る
mm leave <name>              # 退出
```

## 使用例

```bash
# メンバー一覧を表示
$ mm
NAME      PEER             TRANSPORT
ttys001   peer-127...      grpc
ttys002   peer-127...      grpc

# メンバーとして参加（ターミナル名を自動使用）
$ mm join claude
Joined as 'ttys001' running 'claude' on port 50051
> _

# 名前を指定して参加
$ mm join /bin/bash -n alice
Joined as 'alice' running '/bin/bash' on port 50051
> _

# 別のターミナルからメッセージを送信
$ mm tell ttys001 "こんにちは"
Sent to 'ttys001': こんにちは

# 退出 (Ctrl+C)
^C
Leaving...
'ttys001' left
```

## アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────┐
│                        community                                │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                    mm (CLI)                              │  │
│   │              swift-argument-parser                       │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              distributed actor Member                    │  │
│   │                                                         │  │
│   │   ┌─────────────────────────────────────────────────┐  │  │
│   │   │  func tell(_ message: String)                   │  │  │
│   │   │  func getName() -> String                       │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
│   │                                                         │  │
│   │   リモート呼び出しは ActorSystem が透過的に処理          │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                    PTY Manager                           │  │
│   │           (pseudo-terminal 作成・入出力管理)              │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              swift-actor-runtime                         │  │
│   │         (エンベロープ・レジストリ・コーデック)              │  │
│   │                                                         │  │
│   │   ActorSystem が remoteCall() を実装                     │  │
│   │   → Transport 非依存でリモートアクターを呼び出し           │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │               swift-peer                            │  │
│   │       (Transport + Discovery プロトコル提供)              │  │
│   │                                                         │  │
│   │   ┌─────────────────────────────────────────────────┐  │  │
│   │   │  Transport Protocol                              │  │  │
│   │   │  - send(to:data:timeout:) → Data                │  │  │
│   │   │  - start() / stop()                             │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
│   │                                                         │  │
│   │   ┌─────────────────────────────────────────────────┐  │  │
│   │   │  PeerDiscovery Protocol                          │  │  │
│   │   │  - discover() → DiscoveredPeer (name, endpoint) │  │  │
│   │   │  - advertise() / stopAdvertising()              │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
│   │                                                         │  │
│   │   ┌─────────────┬─────────────┬─────────────────────┐  │  │
│   │   │ LocalNetwork│   Nearby    │   RemoteNetwork     │  │  │
│   │   │   (mDNS)    │   (BLE)     │   (Bootstrap)       │  │  │
│   │   └─────────────┴─────────────┴─────────────────────┘  │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │              Transport 実装 (community)                  │  │
│   │                                                         │  │
│   │   ┌─────────────────────────────────────────────────┐  │  │
│   │   │  GRPCTransport (現在の実装)                      │  │  │
│   │   │  - Peer.Transport プロトコルを実装          │  │  │
│   │   │  - gRPC Swift 2 / Protocol Buffers             │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
│   │                                                         │  │
│   │   将来: BLETransport, WebSocketTransport 等も可能      │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 通信フロー

### join (参加)

```
$ mm join claude
# または: mm join claude -n alice

1. PTY作成 (posix_spawn使用)
   ┌─────────────────────────────────────┐
   │  master ←→ slave                    │
   │              ↓                      │
   │           claude                    │
   └─────────────────────────────────────┘

2. swift-peer でサービス登録
   ┌─────────────────────────────────────┐
   │  mDNS/Bonjour でサービスを広告       │
   │  → _community._tcp.local            │
   │  → ホスト名、ポート、メタデータを公開  │
   └─────────────────────────────────────┘

3. Transport Server 起動
   ┌─────────────────────────────────────┐
   │  GRPCServer (または他の実装)          │
   │  → 指定ポートで起動 (default: 50051)│
   │  → dataHandler で受信処理            │
   └─────────────────────────────────────┘

4. Member アクター作成
   ┌─────────────────────────────────────┐
   │  Member(name, pty, actorSystem)     │
   │  → NameRegistry に登録              │
   │  → tell() で PTY に書き込み可能     │
   └─────────────────────────────────────┘

5. ターミナルにアタッチ (raw mode)
   ┌─────────────────────────────────────┐
   │  $ claude                           │
   │  > _                                │
   │  stdin → PTY, PTY → stdout 転送     │
   └─────────────────────────────────────┘
```

### tell (送信)

```
$ mm tell alice "こんにちは"

1. swift-peer でピア発見
   ┌─────────────────────────────────────┐
   │  LocalNetworkDiscovery.discover()   │
   │  → mDNS で _community._tcp を検索   │
   │  → alice のエンドポイント情報を取得   │
   │     (host: 192.168.1.10, port: 50051)│
   └─────────────────────────────────────┘

2. Distributed Actor で透過的に呼び出し
   ┌─────────────────────────────────────┐
   │  let alice = Member.resolve(...)    │
   │  try await alice.tell("こんにちは")  │
   │                                     │
   │  ActorSystem.remoteCallVoid() が    │
   │  Transport 経由で送信を実行          │
   └─────────────────────────────────────┘

3. alice 側: ActorSystem が受信
   ┌─────────────────────────────────────┐
   │  handleIncomingData() 実行           │
   │  → InvocationDecoder でデコード      │
   │  → Member.tell() を呼び出し          │
   │  → pty.writeLine("こんにちは")        │
   │  → claude が入力として受け取る       │
   └─────────────────────────────────────┘
```

### mm (一覧)

```
$ mm

1. swift-peer で全ピア検索
   ┌─────────────────────────────────────┐
   │  LocalNetworkDiscovery.discover()   │
   │  → mDNS で _community._tcp を検索   │
   │  → 全ピアのリストを取得              │
   └─────────────────────────────────────┘

2. 各ピアに MemberQuery を送信
   ┌─────────────────────────────────────┐
   │  for peer in discoveredPeers:       │
   │    members = query(peer, listMembers)│
   │  → 各ピアのメンバー情報を収集         │
   └─────────────────────────────────────┘

3. 一覧表示
   ┌─────────────────────────────────────┐
   │  NAME      TRANSPORT        JOINED  │
   │  alice     grpc             2m ago  │
   │  bob       grpc             5m ago  │
   └─────────────────────────────────────┘
```

## swift-peer の役割

swift-peer は **ピア通信のためのプロトコルライブラリ** である。

- **PeerDiscovery**: ピアを発見する（mDNS, BLE, Bootstrap Server）
- **Transport**: ピアとデータをやり取りする（gRPC, BLE, WebSocket）

両者は同じデバイス能力（ネットワーク、BLE など）に依存するため、同一パッケージで管理する。

### 提供するプロトコル

```swift
/// データ転送プロトコル
public protocol Transport: Sendable {
    var localPeerInfo: PeerInfo { get }
    func start() async throws
    func stop() async throws
    func send(to peerID: PeerID, data: Data, timeout: Duration) async throws -> Data
    var connectedPeers: [PeerID] { get async }
    var events: AsyncStream<TransportEvent> { get async }
}

/// ピア発見プロトコル
public protocol PeerDiscovery: Sendable {
    func discover(timeout: Duration) -> AsyncThrowingStream<DiscoveredPeer, Error>
    func advertise(info: ServiceInfo) async throws
    func stopAdvertising() async throws
    var events: AsyncStream<DiscoveryEvent> { get async }
}

/// 発見されたピア情報
public struct DiscoveredPeer: Sendable {
    public let peerID: PeerID
    public let name: String
    public let endpoint: Endpoint
    public let metadata: [String: String]
    public let discoveredAt: Date
}

/// エンドポイント情報
public struct Endpoint: Sendable, Hashable {
    public let host: String
    public let port: Int
}
```

### 実装例

```swift
// Discovery: mDNS でピアを発見
let discovery = LocalNetworkDiscovery(serviceType: "_community._tcp")

for try await peer in discovery.discover(timeout: .seconds(5)) {
    print("Found: \(peer.name) at \(peer.endpoint.host):\(peer.endpoint.port)")
}

// Transport: gRPC でデータを送信
let transport = GRPCTransport(
    localPeerInfo: peerInfo,
    config: .init(serverEnabled: true),
    discovery: discovery  // オプションで Discovery を注入
)

try await transport.start()  // サーバー起動 + mDNS 広告
```

### 将来の拡張

| Discovery | Transport | 用途 |
|-----------|-----------|------|
| LocalNetworkDiscovery (mDNS) | GRPCTransport | LAN 内通信 |
| NearbyDiscovery (BLE) | BLETransport | 近接通信 |
| BootstrapDiscovery | WebSocketTransport | インターネット経由 |
| CompositeDiscovery | 複数 Transport | ハイブリッド |

## モジュール構成

```
Sources/Community/
├── CLI/
│   ├── CLI.swift             # @main エントリーポイント (MM: AsyncParsableCommand)
│   ├── JoinCommand.swift     # mm join
│   ├── TellCommand.swift     # mm tell
│   ├── LeaveCommand.swift    # mm leave
│   └── ListCommand.swift     # mm (一覧)
│
├── Actor/
│   ├── Member.swift          # distributed actor Member
│   ├── CommunitySystem.swift # ActorSystem実装
│   └── CommunityActorID.swift # Actor識別子
│
├── PTY/
│   └── PTY.swift             # PTY操作 (posix_spawn使用)
│
└── Transport/
    ├── GRPCTransport.swift         # gRPCベースのTransport実装
    ├── GRPCTransportState.swift    # 接続状態管理
    └── Protos/
        └── community.proto         # gRPCサービス定義
```

## 依存関係

```swift
// Package.swift
dependencies: [
    .package(path: "../swift-actor-runtime"),
    .package(path: "../swift-peer"),  // Peer モジュールを提供
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.2"),
]

// import
import Peer  // PeerID, Transport, PeerDiscovery など
```

## Protocol Buffer 定義

```protobuf
// community.proto
syntax = "proto3";

package community;

option swift_prefix = "Proto";

// Transport レベルの RPC サービス
// Discovery は swift-peer が担当するため、ここには含まない
service CommunityTransport {
    // データ送信 (InvocationEnvelope)
    rpc Send(SendRequest) returns (SendResponse);

    // ハートビート
    rpc Heartbeat(HeartbeatRequest) returns (HeartbeatResponse);
}

message SendRequest {
    string targetPeerId = 1;
    string senderPeerId = 2;
    bytes data = 3;
    int64 timeoutMilliseconds = 4;
    string requestId = 5;
}

message SendResponse {
    bool success = 1;
    bytes data = 2;
    string errorMessage = 3;
}

message HeartbeatRequest {
    string peerId = 1;
}

message HeartbeatResponse {
    bool alive = 1;
}
```

## 対応プラットフォーム

- macOS 26+
- Swift 6.2+

## 将来の拡張

### watch (出力監視)

```bash
$ mm watch alice
# alice の出力をリアルタイムで表示
```

### broadcast (全員に送信)

```bash
$ mm broadcast "全員に通知"
```

### group (グループ化)

```bash
$ mm group create team-a alice bob
$ mm tell @team-a "チームに通知"
```

### 複数 Transport のサポート

```bash
# gRPC (デフォルト)
$ mm join claude

# WebSocket
$ mm join claude --transport websocket

# TCP (軽量)
$ mm join claude --transport tcp
```
