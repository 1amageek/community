import Foundation
import Distributed
import Synchronization
import PeerNode

/// Distributed actor system for the Community project
///
/// Bridges swift-actor-runtime with swift-peer to enable
/// distributed actor communication across networks.
///
/// CommunitySystem uses PeerNode to manage peer connections,
/// routing messages to the appropriate transport based on ActorID's peerID.
public final class CommunitySystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = CommunityActorID
    public typealias InvocationEncoder = CodableInvocationEncoder
    public typealias InvocationDecoder = CodableInvocationDecoder
    public typealias ResultHandler = CodableResultHandler
    public typealias SerializationRequirement = Codable

    // MARK: - Components

    /// Actor registry for local actors (by UUID)
    let registry: ActorRegistry

    /// Name registry: name → ActorID mapping
    let nameRegistry: NameRegistry

    /// Local peer information
    public let localPeerInfo: PeerInfo

    /// PeerNode for managing connections
    let node: PeerNode

    // MARK: - State Management

    /// Thread-safe state for peer management
    struct State: ~Copyable {
        var isStarted: Bool = false
        var responseRoutes: [String: String] = [:]  // callID → senderPeerID.value
        var messageTasks: [Task<Void, Never>] = []
        var acceptTask: Task<Void, Never>?
        var remoteMembers: [String: MemberInfo] = [:]  // key: actorID.id -> MemberInfo
    }
    let state = Mutex(State())

    /// Pending remote calls waiting for responses
    let pendingCalls = Mutex<[String: CheckedContinuation<ResponseEnvelope, Error>]>([:])

    // MARK: - Initialization

    /// Create a new CommunitySystem with a PeerNode
    ///
    /// - Parameters:
    ///   - name: Display name for this peer
    ///   - node: The PeerNode managing connections
    public init(name: String, node: PeerNode) {
        self.node = node

        // Initialize local peer info from node
        self.localPeerInfo = PeerInfo(
            peerID: node.localPeerID,
            displayName: name
        )

        // Initialize registries
        self.registry = ActorRegistry()
        self.nameRegistry = NameRegistry()
    }

    // MARK: - Lifecycle

    /// Start the system
    public func start() async throws {
        // Check and set started state atomically
        let alreadyStarted = state.withLock { s -> Bool in
            if s.isStarted {
                return true
            }
            s.isStarted = true
            return false
        }
        guard !alreadyStarted else { return }

        // Create SystemActor immediately so it's available for member queries
        _ = createSystemActor()

        // Start accepting connections (low priority to avoid interfering with PTY)
        let acceptTask: Task<Void, Never> = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.acceptConnections()
        }

        state.withLock { s in
            s.acceptTask = acceptTask
        }
    }

    /// Stop the system
    public func stop() async throws {
        // Get state and clear atomically
        let (wasStarted, tasks, acceptTask) = state.withLock { s -> (Bool, [Task<Void, Never>], Task<Void, Never>?) in
            if !s.isStarted {
                return (false, [], nil)
            }
            s.isStarted = false
            let tasks = s.messageTasks
            let acceptTask = s.acceptTask
            s.responseRoutes.removeAll()
            s.messageTasks.removeAll()
            s.acceptTask = nil
            return (true, tasks, acceptTask)
        }
        guard wasStarted else { return }

        // Cancel all tasks
        acceptTask?.cancel()
        for task in tasks {
            task.cancel()
        }

        // Cancel all pending calls
        let pending = pendingCalls.withLock { pending in
            let copy = pending
            pending.removeAll()
            return copy
        }
        for (_, continuation) in pending {
            continuation.resume(throwing: CommunityError.systemStopped)
        }

        // Stop the node
        await node.stop()

        registry.clear()
        nameRegistry.clear()
    }

    // MARK: - DistributedActorSystem Protocol

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        // For local actors, lookup in registry by UUID
        if id.peerID == localPeerInfo.peerID {
            return registry.find(id: id.id) as? Act
        }
        // For remote actors, return nil (Swift creates a proxy)
        return nil
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID {
        // Use well-known ID for SystemActor
        if actorType == SystemActor.self {
            return CommunityActorID(id: SystemActor.wellKnownID, peerID: localPeerInfo.peerID)
        }
        return CommunityActorID(peerID: localPeerInfo.peerID)
    }

    public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID {
        // Register by UUID
        registry.register(actor, id: actor.id.id)
    }

    public func resignID(_ id: ActorID) {
        // Unregister from both registries
        registry.unregister(id: id.id)
        nameRegistry.unregisterByActorID(id)
    }

    public func makeInvocationEncoder() -> InvocationEncoder {
        CodableInvocationEncoder()
    }
}
