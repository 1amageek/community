import Testing
import Foundation
import Discovery
@testable import Community

@Suite("CommunityActorID Tests")
struct CommunityActorIDTests {

    @Test("Init with explicit ID preserves values")
    func initWithExplicitID() {
        let peerID = PeerID("test-peer")
        let actorID = CommunityActorID(id: "my-id", peerID: peerID)

        #expect(actorID.id == "my-id")
        #expect(actorID.peerID == peerID)
    }

    @Test("Init with peerID only generates UUID")
    func initGeneratesUUID() {
        let peerID = PeerID("test-peer")
        let actorID1 = CommunityActorID(peerID: peerID)
        let actorID2 = CommunityActorID(peerID: peerID)

        #expect(actorID1.id != actorID2.id)
        #expect(actorID1.peerID == peerID)
    }

    @Test("Description format is correct")
    func descriptionFormat() {
        let peerID = PeerID("test-peer")
        let actorID = CommunityActorID(id: "12345678-90ab-cdef", peerID: peerID)

        #expect(actorID.description == "12345678@test-peer")
    }

    @Test("Hashable works in Set")
    func hashableInSet() {
        let peerID = PeerID("test-peer")
        let actorID1 = CommunityActorID(id: "id-1", peerID: peerID)
        let actorID2 = CommunityActorID(id: "id-2", peerID: peerID)
        let actorID3 = CommunityActorID(id: "id-1", peerID: peerID)  // duplicate

        var set: Set<CommunityActorID> = []
        set.insert(actorID1)
        set.insert(actorID2)
        set.insert(actorID3)

        #expect(set.count == 2)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let peerID = PeerID("test-peer")
        let original = CommunityActorID(id: "test-id", peerID: peerID)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommunityActorID.self, from: encoded)

        #expect(decoded == original)
    }

    @Test("Equality requires both id and peerID match")
    func equalityRequiresBothMatch() {
        let actorID1 = CommunityActorID(id: "same-id", peerID: PeerID("peer-1"))
        let actorID2 = CommunityActorID(id: "same-id", peerID: PeerID("peer-2"))
        let actorID3 = CommunityActorID(id: "diff-id", peerID: PeerID("peer-1"))
        let actorID4 = CommunityActorID(id: "same-id", peerID: PeerID("peer-1"))

        #expect(actorID1 != actorID2)  // different peer
        #expect(actorID1 != actorID3)  // different id
        #expect(actorID1 == actorID4)  // same both
    }
}
