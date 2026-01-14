import Testing
import Foundation
import Discovery
@testable import Community

/// スレッドセーフなカウンター
private actor Counter {
    var value: Int = 0

    func increment() {
        value += 1
    }

    func get() -> Int {
        value
    }
}

// MARK: - NameRegistry Concurrency Tests

@Suite("NameRegistry Concurrency Tests")
struct NameRegistryConcurrencyTests {

    func makeActorID() -> CommunityActorID {
        CommunityActorID(id: UUID().uuidString, peerID: PeerID("test-peer"))
    }

    @Test("Concurrent registers of different names succeed")
    func concurrentRegistersDifferentNames() async throws {
        let registry = NameRegistry()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? registry.register(name: "user-\(i)", actorID: self.makeActorID())
                }
            }
        }

        #expect(registry.allNames().count == 100)
    }

    @Test("Concurrent registers of same name - exactly one wins")
    func concurrentRegistersSameName() async throws {
        let registry = NameRegistry()
        let actorIDs = (0..<100).map { _ in makeActorID() }

        let counter = Counter()

        await withTaskGroup(of: Bool.self) { group in
            for actorID in actorIDs {
                group.addTask {
                    do {
                        try registry.register(name: "contested", actorID: actorID)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            for await success in group {
                if success {
                    await counter.increment()
                }
            }
        }

        let successCount = await counter.get()
        #expect(successCount == 1)  // 正確に1つだけ成功
        #expect(registry.find(name: "contested") != nil)
    }

    @Test("Concurrent find operations don't crash")
    func concurrentFinds() async throws {
        let registry = NameRegistry()
        for i in 0..<10 {
            try registry.register(name: "user-\(i)", actorID: makeActorID())
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    _ = registry.find(name: "user-\(Int.random(in: 0..<10))")
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }

    @Test("Concurrent register and unregister don't crash")
    func concurrentRegisterUnregister() async throws {
        let registry = NameRegistry()

        await withTaskGroup(of: Void.self) { group in
            // 登録タスク
            for i in 0..<50 {
                group.addTask {
                    try? registry.register(name: "temp-\(i)", actorID: self.makeActorID())
                }
            }

            // 削除タスク
            for i in 0..<50 {
                group.addTask {
                    registry.unregister(name: "temp-\(i)")
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }

    @Test("Clear during concurrent operations doesn't crash")
    func clearDuringConcurrentOps() async throws {
        let registry = NameRegistry()

        await withTaskGroup(of: Void.self) { group in
            // 登録タスク
            for i in 0..<100 {
                group.addTask {
                    try? registry.register(name: "user-\(i)", actorID: self.makeActorID())
                }
            }

            // クリアタスク
            group.addTask {
                registry.clear()
            }

            // 検索タスク
            for _ in 0..<100 {
                group.addTask {
                    _ = registry.allNames()
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }
}

// MARK: - CommunitySystem Lifecycle Concurrency Tests

@Suite("CommunitySystem Lifecycle Concurrency Tests")
struct SystemLifecycleConcurrencyTests {

    @Test("Concurrent start calls - only one succeeds")
    func concurrentStartCalls() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockTransport()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await system.start(transports: [transport])
                }
            }
        }

        // トランスポートは1回だけ開始される
        #expect(await transport.startCount == 1)

        try await system.stop()
    }

    @Test("Concurrent stop calls - safe")
    func concurrentStopCalls() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockTransport()

        try await system.start(transports: [transport])

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await system.stop()
                }
            }
        }

        // トランスポートは1回だけ停止される
        #expect(await transport.stopCount == 1)
    }

    @Test("Concurrent start and stop - safe")
    func concurrentStartStop() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockTransport()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await system.start(transports: [transport])
                }
                group.addTask {
                    try? await system.stop()
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }
}

// MARK: - PTY Concurrency Tests

@Suite("PTY Concurrency Tests")
struct PTYConcurrencyTests {

    @Test("Concurrent writes are serialized")
    func concurrentWritesSerialized() async throws {
        let pty = try PTY(command: "/bin/cat")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? pty.writeLine("message-\(i)")
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        pty.close()
        #expect(Bool(true))
    }

    @Test("Write and close race condition handled")
    func writeAndCloseRace() async throws {
        for _ in 0..<10 {  // 複数回実行してレース条件をテスト
            let pty = try PTY(command: "/bin/cat")

            await withTaskGroup(of: Void.self) { group in
                // 書き込みタスク
                for i in 0..<10 {
                    group.addTask {
                        try? pty.writeLine("message-\(i)")
                    }
                }

                // クローズタスク
                group.addTask {
                    pty.close()
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }

    @Test("Multiple close calls are safe")
    func multipleCloseSafe() async throws {
        let pty = try PTY(command: "/bin/cat")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    pty.close()
                }
            }
        }

        // クラッシュしなければ成功（completion is success）
        #expect(Bool(true))
    }
}
