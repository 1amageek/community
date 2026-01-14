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
│   │   │  func output() -> AsyncStream<String>           │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
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
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                    gRPC Swift 2                          │  │
│   │                   (RPC通信基盤)                           │  │
│   │                                                         │  │
│   │   ┌─────────────────────────────────────────────────┐  │  │
│   │   │  Stub層: CommunityTransport (protobuf生成)      │  │  │
│   │   ├─────────────────────────────────────────────────┤  │  │
│   │   │  Call層: RPC実行・シリアライズ                    │  │  │
│   │   ├─────────────────────────────────────────────────┤  │  │
│   │   │  Transport層: grpc-swift-nio-transport (HTTP/2) │  │  │
│   │   └─────────────────────────────────────────────────┘  │  │
│   └─────────────────────────────────────────────────────────┘  │
│                            │                                    │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │               swift-discovery                            │  │
│   │              (ピア発見・接続)                             │  │
│   │                                                         │  │
│   │   ┌─────────────┬─────────────┬─────────────────────┐  │  │
│   │   │ LocalNetwork│   Nearby    │   RemoteNetwork     │  │  │
│   │   │   (mDNS)    │   (BLE)     │   (Internet)        │  │  │
│   │   └─────────────┴─────────────┴─────────────────────┘  │  │
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

2. gRPC Server 起動
   ┌─────────────────────────────────────┐
   │  GRPCServer(CommunityTransport)     │
   │  → 指定ポートで起動 (default: 50051)│
   │  → dataHandler で受信処理            │
   └─────────────────────────────────────┘

3. Member アクター作成
   ┌─────────────────────────────────────┐
   │  Member(name, pty, actorSystem)     │
   │  → NameRegistry に登録              │
   │  → tell() で PTY に書き込み可能     │
   └─────────────────────────────────────┘

4. ターミナルにアタッチ (raw mode)
   ┌─────────────────────────────────────┐
   │  $ claude                           │
   │  > _                                │
   │  stdin → PTY, PTY → stdout 転送     │
   └─────────────────────────────────────┘
```

### tell (送信)

```
$ mm tell alice "こんにちは"

1. swift-discovery でピア発見 (findMember)
   ┌─────────────────────────────────────┐
   │  coordinator.discover(timeout)       │
   │  → 各ピアに MemberQuery 送信         │
   │  → alice の ActorID を取得           │
   └─────────────────────────────────────┘

2. gRPC Client で接続・呼び出し
   ┌─────────────────────────────────────┐
   │  GRPCClient(target: alice.endpoint)  │
   │  CommunityTransport.Send(data)       │
   │  → InvocationEnvelope をシリアライズ  │
   └─────────────────────────────────────┘

3. alice 側: gRPC Server が受信
   ┌─────────────────────────────────────┐
   │  handleIncomingData() 実行           │
   │  → Member.tell() を呼び出し          │
   │  → pty.writeLine("こんにちは")        │
   │  → claude が入力として受け取る       │
   └─────────────────────────────────────┘
```

### mm (一覧)

```
$ mm

1. swift-discovery で全ピア検索
   ┌─────────────────────────────────────┐
   │  discoverMembers(timeout)           │
   │  → 各ピアに MemberQuery(listMembers) │
   │  → MemberInfo リストを取得           │
   └─────────────────────────────────────┘

2. 一覧表示
   ┌─────────────────────────────────────┐
   │  NAME      TRANSPORT        JOINED  │
   │  alice     grpc             2m ago  │
   │  bob       grpc             5m ago  │
   └─────────────────────────────────────┘
```

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
    ├── TransportCoordinator.swift  # Transport調整
    └── Protos/
        └── community.proto         # gRPCサービス定義
```

## Protocol Buffer 定義

```protobuf
// community.proto
syntax = "proto3";

package community;

option swift_prefix = "Proto";

service CommunityTransport {
    // ピア発見
    rpc Discover(DiscoverRequest) returns (stream DiscoveredPeerID);

    // ピア情報解決
    rpc Resolve(ResolveRequest) returns (ResolveResponse);

    // データ送信 (InvocationEnvelope / MemberQuery)
    rpc Send(SendRequest) returns (SendResponse);

    // イベント購読
    rpc Subscribe(SubscribeRequest) returns (stream TransportEvent);

    // ピア登録
    rpc Register(RegisterRequest) returns (RegisterResponse);

    // ハートビート
    rpc Heartbeat(HeartbeatRequest) returns (HeartbeatResponse);
}

message PeerInfo {
    string peerId = 1;
    string displayName = 2;
    map<string, string> metadata = 3;
}

message DiscoverRequest {
    int64 timeoutMilliseconds = 1;
}

message DiscoveredPeerID {
    string peerId = 1;
}

message ResolveRequest {
    string peerId = 1;
}

message ResolveResponse {
    bool found = 1;
    PeerInfo peer = 2;
    int64 ttlSeconds = 3;
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

message TransportEvent {
    oneof event {
        PeerDiscoveredEvent peerDiscovered = 1;
        PeerLostEvent peerLost = 2;
        MessageReceivedEvent messageReceived = 3;
        ErrorEvent error = 4;
    }
}
```

## 依存関係

```swift
// Package.swift
dependencies: [
    .package(path: "../swift-actor-runtime"),
    .package(path: "../swift-discovery"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.4.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.2"),
]
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
