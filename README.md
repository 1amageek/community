# Community

分散アクター型のメンバー管理システム。複数のターミナルセッション間でネットワークを通じて通信・コラボレーションを可能にします。

Swift の Distributed Actors と gRPC を使用し、異なるマシン上のメンバー間でメッセージを送受信できます。

## 必要要件

- macOS 26+
- Swift 6.2+

## インストール

```bash
git clone https://github.com/1amageek/community.git
cd community
swift build
```

## 使い方

### コミュニティに参加する

```bash
# デフォルトのシェル（/bin/bash）で参加
swift run mm join

# カスタムコマンドで参加
swift run mm join /bin/zsh

# 名前とポートを指定
swift run mm join /bin/bash -n alice -p 50051
```

参加すると PTY（擬似端末）が起動し、コマンドが実行されます。終了するには `Ctrl+C` を押してください。

### メンバーにメッセージを送る

```bash
# ローカルホストのメンバーにメッセージを送信
swift run mm tell alice "Hello, Alice!"

# リモートホストのメンバーにメッセージを送信
swift run mm tell alice "Hello!" -h 192.168.1.100 -p 50051
```

メッセージは対象メンバーの PTY に入力として送信されます。

### メンバー一覧を表示する

```bash
# ローカルホストのメンバーを表示
swift run mm list

# リモートホストのメンバーを表示
swift run mm list -h 192.168.1.100 -p 50051

# デフォルトコマンド（listと同じ）
swift run mm -h 192.168.1.100
```

## コマンド一覧

| コマンド | 説明 |
|---------|------|
| `mm join [command]` | コミュニティに参加 |
| `mm tell <name> <message>` | メンバーにメッセージを送信 |
| `mm list` | メンバー一覧を表示 |
| `mm leave` | コミュニティから離脱（Ctrl+Cを使用） |

### オプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `-n, --name` | メンバー名 | TTY名またはホスト名 |
| `-h, --host` | 接続先ホスト | 127.0.0.1 |
| `-p, --port` | 接続先ポート | 50051 |

## アーキテクチャ

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

### コンポーネント

- **CommunitySystem**: Distributed Actor System の実装。ローカル・リモートアクターの管理
- **Member**: 各参加者を表す分散アクター。PTY を所有しメッセージを受信
- **SystemActor**: メンバーの検索・一覧取得を提供するシステムアクター
- **PTY**: POSIX 擬似端末の管理。プロセスの入出力を制御

## 依存関係

- [swift-peer](https://github.com/1amageek/swift-peer) - gRPC トランスポートと分散システム基盤
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) - CLI パーサー

## ライセンス

MIT License
