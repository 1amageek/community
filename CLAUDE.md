# Community Project

## プロジェクト目標

**同一マシンのターミナルも、リモートマシンのターミナルも区別なく使える P2P メッシュシステム**

### コア要件

1. **透過的な名前解決**: `mm tell alice "hello"` で、alice がローカルにいてもリモートにいても同じコマンドで送信できる
2. **P2P アーキテクチャ**: 中央サーバーなし。全ピアが対等
3. **Swift Distributed Actor**: ActorID ベースのルーティングで、アプリケーション層は接続先を意識しない

### 設計原則

1. **PeerID は接続情報を含む**: `name@host:port` 形式で、どこに接続すべきか自己記述的
2. **名前はグローバル**: 接続した全ピア間でメンバー名を共有。NameRegistry はローカル/リモートを区別しない
3. **オンデマンド接続**: ActorID の peerID から必要に応じて Transport を作成
4. **Handshake Protocol**: 接続確立時にメンバー一覧を交換
5. **MemberAnnouncement**: メンバー追加/削除を全接続ピアにブロードキャスト

### 接続モデル

| 状況 | 動作 | 必要な操作 | 状態 |
|------|------|-----------|------|
| 同一デバイス | ローカルサーバー共有 | なし（自動） | ✅ 実装済み |
| 同一ネットワーク | mDNS で自動発見 | なし（自動） | ⚠️ 一時無効（sandbox制約） |
| 異なるネットワーク | 手動接続 | `--peer` 指定 | ✅ 実装済み |

### ユースケース

#### 同一デバイス（自動共有）
```bash
# Terminal 1
mm join zsh --name alice
# → サーバー起動 (50051)

# Terminal 2
mm join zsh --name bob
# → localhost:50051 に自動接続（サーバー共有）

# Terminal 3
mm list
# → alice, bob 両方が見える
```

#### 同一ネットワーク（自動発見）
```bash
# Machine A
mm join zsh --name alice
# → サーバー起動 (50051)
# → mDNS で広告

# Machine B
mm join zsh --name bob
# → サーバー起動 (50051)
# → mDNS で alice を発見、自動接続

# どちらからも
mm list              # alice, bob 両方が見える
```

#### 異なるネットワーク（手動接続）
```bash
# Machine A (グローバル IP: 203.0.113.10)
mm join zsh --name alice

# Machine B
mm join zsh --name bob --peer alice@203.0.113.10:50051
```

### アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────────┐
│                      CommunitySystem                            │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ NameRegistry: name → ActorID (local/remote 区別なし)      │ │
│  └───────────────────────────────────────────────────────────┘ │
│                              │                                  │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ MeshNode: P2P 接続管理                                    │ │
│  │   - GRPCServer: 接続受付                                  │ │
│  │   - Routes: peerID → Transport                            │ │
│  │   - Handshake: メンバー情報交換                           │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## ビルド方法

```bash
swift build
swift test
swift run mm
```

## 依存関係

- `swift-peer`: Transport と Discovery を提供（PeerNode モジュール経由）
- `swift-argument-parser`: CLI パーサー
- `swift-actor-runtime`: Distributed Actor の Codec と Registry

---

## 禁止事項（絶対に守ること）

### swift-peer 内部実装への直接依存禁止

**community は以下を直接使用してはならない:**

| 禁止 | 理由 |
|------|------|
| `import PeerGRPC` | 実装詳細への依存 |
| `import PeerSocket` | 実装詳細への依存 |
| `GRPCServer` | 低レベル API |
| `GRPCTransport` | 低レベル API |
| `GRPCServerConnection` | 低レベル API |
| `UnixSocketServer` | 低レベル API |
| `UnixSocketTransport` | 低レベル API |

**正しい依存:**
```swift
import PeerNode  // これだけ

let node = PeerNode(name: "alice", port: 50051)
try await node.start()
```

**理由:**
1. **責務の分離** - community はビジネスロジックに集中
2. **エラーハンドリング** - ポート競合等は PeerNode が処理
3. **将来の変更** - Transport 変更時に community は無修正

### 依存関係図

```
community (CommunitySystem, JoinCommand)
    │
    │  import PeerNode ← これだけ許可
    ↓
swift-peer/PeerNode
    │
    │  内部で使用（community は知らない）
    ↓
swift-peer/PeerGRPC, PeerSocket
```

---

## 実装状況

### 完了

- [x] PeerNode 抽象レイヤー経由の通信
- [x] 同一デバイスでの自動ポートフォールバック
- [x] 既存サーバーへの自動接続
- [x] Member 交換プロトコル（双方向）
- [x] `mm list` で local + remote メンバー表示
- [x] `mm tell` でリモートメンバーにメッセージ送信

### 一時無効

- [ ] mDNS 広告・発見（sandbox/entitlement 制約で無効化中）

### 今後の課題

- [ ] mDNS 対応（要 entitlement 設定）
- [ ] メンバー離脱時の通知（MemberAnnouncement）
- [ ] 接続断時の自動再接続
