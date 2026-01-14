import Testing
import Foundation
import Peer
@testable import CommunityCore

@Suite("NameRegistry Tests")
struct NameRegistryTests {

    // テスト用のヘルパー
    func makeActorID(_ id: String = UUID().uuidString) -> CommunityActorID {
        CommunityActorID(id: id, peerID: PeerID("test-peer"))
    }

    // MARK: - 基本操作テスト

    @Test("Register new name succeeds")
    func registerNewName() throws {
        let registry = NameRegistry()
        let actorID = makeActorID()

        try registry.register(name: "alice", actorID: actorID)

        let found = registry.find(name: "alice")
        #expect(found == actorID)
    }

    @Test("Register duplicate name throws nameAlreadyTaken")
    func registerDuplicateThrows() throws {
        let registry = NameRegistry()
        let actorID1 = makeActorID()
        let actorID2 = makeActorID()

        try registry.register(name: "alice", actorID: actorID1)

        #expect {
            try registry.register(name: "alice", actorID: actorID2)
        } throws: { error in
            guard let communityError = error as? CommunityError else { return false }
            if case .nameAlreadyTaken("alice") = communityError {
                return true
            }
            return false
        }
    }

    @Test("Find existing name returns actorID")
    func findExistingName() throws {
        let registry = NameRegistry()
        let actorID = makeActorID()
        try registry.register(name: "bob", actorID: actorID)

        let found = registry.find(name: "bob")
        #expect(found == actorID)
    }

    @Test("Find non-existent name returns nil")
    func findNonExistentReturnsNil() {
        let registry = NameRegistry()

        let found = registry.find(name: "nobody")
        #expect(found == nil)
    }

    @Test("Unregister existing name succeeds")
    func unregisterExisting() throws {
        let registry = NameRegistry()
        let actorID = makeActorID()
        try registry.register(name: "carol", actorID: actorID)

        registry.unregister(name: "carol")

        #expect(registry.find(name: "carol") == nil)
    }

    @Test("Unregister non-existent name is idempotent")
    func unregisterNonExistentIsIdempotent() {
        let registry = NameRegistry()

        // Should not throw
        registry.unregister(name: "nobody")
        registry.unregister(name: "nobody")
    }

    @Test("UnregisterByActorID removes all names for actor")
    func unregisterByActorIDRemovesAllNames() throws {
        let registry = NameRegistry()
        let actorID = makeActorID("actor-1")

        try registry.register(name: "alias1", actorID: actorID)
        try registry.register(name: "alias2", actorID: actorID)

        registry.unregisterByActorID(actorID)

        #expect(registry.find(name: "alias1") == nil)
        #expect(registry.find(name: "alias2") == nil)
    }

    @Test("allNames returns all registered names")
    func allNamesReturnsAll() throws {
        let registry = NameRegistry()
        try registry.register(name: "alice", actorID: makeActorID())
        try registry.register(name: "bob", actorID: makeActorID())

        let names = registry.allNames()

        #expect(names.count == 2)
        #expect(names.contains("alice"))
        #expect(names.contains("bob"))
    }

    @Test("allEntries returns all name-actorID pairs")
    func allEntriesReturnsAll() throws {
        let registry = NameRegistry()
        let actorID1 = makeActorID()
        let actorID2 = makeActorID()
        try registry.register(name: "alice", actorID: actorID1)
        try registry.register(name: "bob", actorID: actorID2)

        let entries = registry.allEntries()

        #expect(entries.count == 2)
    }

    @Test("clear removes all entries")
    func clearRemovesAll() throws {
        let registry = NameRegistry()
        try registry.register(name: "alice", actorID: makeActorID())
        try registry.register(name: "bob", actorID: makeActorID())

        registry.clear()

        #expect(registry.allNames().isEmpty)
    }

    // MARK: - エッジケース

    @Test("Register empty name")
    func registerEmptyName() throws {
        let registry = NameRegistry()
        try registry.register(name: "", actorID: makeActorID())

        #expect(registry.find(name: "") != nil)
    }

    @Test("Register name with special characters")
    func registerSpecialCharacters() throws {
        let registry = NameRegistry()
        let specialNames = ["日本語", "emoji🎉", "space name", "tab\tname"]

        for name in specialNames {
            try registry.register(name: name, actorID: makeActorID())
            #expect(registry.find(name: name) != nil)
        }
    }

    @Test("Register very long name")
    func registerVeryLongName() throws {
        let registry = NameRegistry()
        let longName = String(repeating: "a", count: 10000)

        try registry.register(name: longName, actorID: makeActorID())
        #expect(registry.find(name: longName) != nil)
    }
}
