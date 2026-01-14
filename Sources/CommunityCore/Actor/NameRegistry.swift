import Foundation
import Synchronization

/// Thread-safe registry for name → ActorID mappings
final class NameRegistry: Sendable {
    private struct State {
        var names: [String: CommunityActorID] = [:]
    }

    private let mutex = Mutex(State())

    init() {}

    func register(name: String, actorID: CommunityActorID) throws {
        try mutex.withLock { state in
            if state.names[name] != nil {
                throw CommunityError.nameAlreadyTaken(name)
            }
            state.names[name] = actorID
        }
    }

    func find(name: String) -> CommunityActorID? {
        mutex.withLock { state in
            state.names[name]
        }
    }

    func unregister(name: String) {
        mutex.withLock { state in
            _ = state.names.removeValue(forKey: name)
        }
    }

    func unregisterByActorID(_ actorID: CommunityActorID) {
        mutex.withLock { state in
            state.names = state.names.filter { $0.value != actorID }
        }
    }

    func allNames() -> [String] {
        mutex.withLock { state in
            Array(state.names.keys)
        }
    }

    func allEntries() -> [(String, CommunityActorID)] {
        mutex.withLock { state in
            Array(state.names).map { ($0.key, $0.value) }
        }
    }

    func clear() {
        mutex.withLock { state in
            state.names.removeAll()
        }
    }
}
