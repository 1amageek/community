import Testing
import Foundation
import Peer
@testable import CommunityCore

@Suite("CommunitySystem Tests")
struct CommunitySystemTests {

    // MARK: - 初期化テスト

    @Test("Init with default name uses hostname")
    func initWithDefaultName() {
        let system = CommunitySystem()
        #expect(system.localPeerInfo.peerID.value == ProcessInfo.processInfo.hostName)
    }

    @Test("Init with custom name uses provided name")
    func initWithCustomName() {
        let system = CommunitySystem(name: "test-peer")
        #expect(system.localPeerInfo.peerID.value == "test-peer")
    }

    // MARK: - ライフサイクルテスト

    @Test("Start is idempotent")
    func startIsIdempotent() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockDistributedTransport()

        try await system.start(transport: transport)
        try await system.start(transport: transport)  // 2回目

        // システムは1回だけ開始される（トランスポートのstartはCommunitySystemが呼ばない）
        try await system.stop()
    }

    @Test("Stop without start is idempotent")
    func stopWithoutStart() async throws {
        let system = CommunitySystem(name: "test")
        try await system.stop()  // エラーにならない
        try await system.stop()  // 2回目もエラーにならない
    }

    @Test("Stop is idempotent")
    func stopIsIdempotent() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockDistributedTransport()
        try await system.start(transport: transport)

        try await system.stop()
        try await system.stop()  // 2回目もエラーにならない
    }

    @Test("Stop clears both registries")
    func stopClearsRegistries() async throws {
        let system = CommunitySystem(name: "test")
        let transport = MockDistributedTransport()
        try await system.start(transport: transport)

        // 名前を登録
        let actorID = system.assignID(Member.self)
        try system.registerName("alice", for: actorID)

        #expect(system.findLocalActorID(byName: "alice") != nil)

        try await system.stop()

        #expect(system.findLocalActorID(byName: "alice") == nil)
        #expect(system.allLocalNames().isEmpty)
    }

    // MARK: - 名前レジストリ操作テスト

    @Test("RegisterName succeeds for new name")
    func registerNameSucceeds() async throws {
        let system = CommunitySystem(name: "test")
        let actorID = system.assignID(Member.self)

        try system.registerName("alice", for: actorID)

        #expect(system.findLocalActorID(byName: "alice") == actorID)
    }

    @Test("RegisterName throws for duplicate name")
    func registerNameThrowsForDuplicate() async throws {
        let system = CommunitySystem(name: "test")
        let actorID1 = system.assignID(Member.self)
        let actorID2 = system.assignID(Member.self)

        try system.registerName("alice", for: actorID1)

        #expect {
            try system.registerName("alice", for: actorID2)
        } throws: { error in
            guard let communityError = error as? CommunityError else { return false }
            if case .nameAlreadyTaken("alice") = communityError {
                return true
            }
            return false
        }
    }

    @Test("UnregisterName removes name")
    func unregisterNameRemoves() async throws {
        let system = CommunitySystem(name: "test")
        let actorID = system.assignID(Member.self)
        try system.registerName("bob", for: actorID)

        system.unregisterName("bob")

        #expect(system.findLocalActorID(byName: "bob") == nil)
    }

    @Test("allLocalNames returns registered names")
    func allLocalNamesReturnsRegistered() async throws {
        let system = CommunitySystem(name: "test")
        try system.registerName("alice", for: system.assignID(Member.self))
        try system.registerName("bob", for: system.assignID(Member.self))

        let names = system.allLocalNames()

        #expect(names.count == 2)
        #expect(names.contains("alice"))
        #expect(names.contains("bob"))
    }

    // MARK: - Actor ID テスト

    @Test("assignID generates unique IDs")
    func assignIDGeneratesUnique() {
        let system = CommunitySystem(name: "test")

        let id1 = system.assignID(Member.self)
        let id2 = system.assignID(Member.self)
        let id3 = system.assignID(Member.self)

        #expect(id1.id != id2.id)
        #expect(id2.id != id3.id)
        #expect(id1.id != id3.id)
    }

    @Test("assignID uses local peerID")
    func assignIDUsesLocalPeerID() {
        let system = CommunitySystem(name: "test-peer")

        let id = system.assignID(Member.self)

        #expect(id.peerID == system.localPeerInfo.peerID)
    }

    // MARK: - Resolve テスト

    @Test("resolve local actor returns instance")
    func resolveLocalReturnsInstance() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")
        let member = try system.createMember(name: "alice", pty: pty)

        let resolved = try system.resolve(id: member.id, as: Member.self)

        #expect(resolved === member)

        pty.close()
    }

    @Test("resolve non-existent local returns nil")
    func resolveNonExistentReturnsNil() async throws {
        let system = CommunitySystem(name: "test")
        let fakeID = CommunityActorID(peerID: system.localPeerInfo.peerID)

        let resolved = try system.resolve(id: fakeID, as: Member.self)

        #expect(resolved == nil)
    }

    @Test("resolve remote actor returns nil for proxy creation")
    func resolveRemoteReturnsNil() async throws {
        let system = CommunitySystem(name: "test")
        let remoteID = CommunityActorID(peerID: PeerID("remote-peer"))

        let resolved = try system.resolve(id: remoteID, as: Member.self)

        #expect(resolved == nil)
    }

    // MARK: - resignID テスト

    @Test("resignID unregisters actor and clears names")
    func resignIDClearsAll() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")
        let member = try system.createMember(name: "alice", pty: pty)
        let memberID = member.id

        #expect(system.findLocalActorID(byName: "alice") != nil)

        system.resignID(memberID)

        #expect(system.findLocalActorID(byName: "alice") == nil)
        #expect(try system.resolve(id: memberID, as: Member.self) == nil)

        pty.close()
    }
}
