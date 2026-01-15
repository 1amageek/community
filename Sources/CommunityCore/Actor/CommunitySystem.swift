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
    private let registry: ActorRegistry

    /// Name registry: name → ActorID mapping
    private let nameRegistry: NameRegistry

    /// Local peer information
    public let localPeerInfo: PeerInfo

    /// PeerNode for managing connections
    private let node: PeerNode

    // MARK: - State Management

    /// Thread-safe state for peer management
    private struct State: ~Copyable {
        var isStarted: Bool = false
        var responseRoutes: [String: String] = [:]  // callID → senderPeerID.value
        var messageTasks: [Task<Void, Never>] = []
        var acceptTask: Task<Void, Never>?
        var remoteMembers: [String: MemberInfo] = [:]  // key: actorID.id -> MemberInfo
    }
    private let state = Mutex(State())

    /// Pending remote calls waiting for responses
    private let pendingCalls = Mutex<[String: CheckedContinuation<ResponseEnvelope, Error>]>([:])

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

        // Start accepting connections
        let acceptTask: Task<Void, Never> = Task { [weak self] in
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

    // MARK: - Peer Management

    /// Connect to a peer
    public func connectToPeer(_ peerID: PeerID) async throws {
        try await node.connect(to: peerID)

        // Start processing messages from this peer
        guard let transport = node.transport(for: peerID) else {
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.processMessages(from: transport, peerID: peerID)
        }

        state.withLock { s in
            s.messageTasks.append(task)
        }

        // Exchange member information with the connected peer
        await exchangeMemberInfo(with: peerID)
    }

    /// Exchange member information with a connected peer
    private func exchangeMemberInfo(with peerID: PeerID) async {
        do {
            let remoteSystemActor = try remoteSystemActor(peerID: peerID)
            let remoteMembers = try await remoteSystemActor.listMembers()

            // Store remote members (skip our own members)
            state.withLock { s in
                for member in remoteMembers {
                    // Don't store our own members
                    if member.peerID != localPeerInfo.peerID {
                        s.remoteMembers[member.actorID.id] = member
                    }
                }
            }
        } catch {
            // Failed to exchange member info - not critical
        }
    }

    /// Get all connected peer IDs
    public func connectedPeers() -> [PeerID] {
        node.connectedPeers
    }

    // MARK: - Connection Handling

    private func acceptConnections() async {
        for await connection in node.incomingConnections {
            let peerID = connection.peerID

            // Start processing messages from this connection
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.processMessages(from: connection.transport, peerID: peerID)
            }

            state.withLock { s in
                s.messageTasks.append(task)
            }

            // Exchange member information with the connected peer
            Task { [weak self] in
                guard let self else { return }
                await self.exchangeMemberInfo(with: peerID)
            }
        }
    }

    private func processMessages(from transport: any DistributedTransport, peerID: PeerID) async {
        do {
            for try await envelope in transport.messages {
                switch envelope {
                case .invocation(let invocation):
                    // Track sender for response routing
                    state.withLock { s in
                        s.responseRoutes[invocation.callID] = peerID.value
                    }

                    // Handle the invocation
                    let response = await handleInvocation(invocation)

                    // Send response back via the same transport
                    try await transport.send(.response(response))

                case .response(let response):
                    // Handle response to a pending call
                    handleResponse(response)
                }
            }
        } catch {
            // Message stream error
        }

        // Cancel all pending calls - connection is gone
        let pending = pendingCalls.withLock { pending in
            let copy = pending
            pending.removeAll()
            return copy
        }
        for (_, continuation) in pending {
            continuation.resume(throwing: CommunityError.connectionFailed("Peer disconnected: \(peerID.name)"))
        }
    }

    // MARK: - Message Processing

    private func handleInvocation(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        // Find the target actor by UUID
        guard let targetActor = registry.find(id: envelope.recipientID) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(RuntimeError.actorNotFound(envelope.recipientID))
            )
        }

        // Create the invocation decoder
        do {
            var decoder = try CodableInvocationDecoder(envelope: envelope)

            // Create a result handler to capture the response
            var capturedResponse: ResponseEnvelope?
            let handler = CodableResultHandler(callID: envelope.callID) { response in
                capturedResponse = response
            }

            // Execute the distributed target
            let target = RemoteCallTarget(envelope.target)
            try await executeDistributedTarget(
                on: targetActor,
                target: target,
                invocationDecoder: &decoder,
                handler: handler
            )

            // Return the response
            if let response = capturedResponse {
                return response
            } else {
                return ResponseEnvelope(
                    callID: envelope.callID,
                    result: .failure(RuntimeError.executionFailed(envelope.target, underlying: "No response captured"))
                )
            }
        } catch {
            let runtimeError: RuntimeError
            if let re = error as? RuntimeError {
                runtimeError = re
            } else {
                runtimeError = RuntimeError.executionFailed(envelope.target, underlying: error.localizedDescription)
            }
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(runtimeError)
            )
        }
    }

    private func handleResponse(_ response: ResponseEnvelope) {
        // Find and resume the pending call
        let continuation = pendingCalls.withLock { pending in
            pending.removeValue(forKey: response.callID)
        }
        continuation?.resume(returning: response)
    }

    // MARK: - Name Registry

    /// Register a name alias for an actor
    public func registerName(_ name: String, for actorID: ActorID) throws {
        try nameRegistry.register(name: name, actorID: actorID)
    }

    /// Unregister a name alias
    public func unregisterName(_ name: String) {
        nameRegistry.unregister(name: name)
    }

    /// Find actor ID by name (local only)
    public func findLocalActorID(byName name: String) -> ActorID? {
        nameRegistry.find(name: name)
    }

    /// Get all registered names (local only)
    public func allLocalNames() -> [String] {
        nameRegistry.allNames()
    }

    /// Get all local members
    public func localMembers() -> [MemberInfo] {
        nameRegistry.allEntries().map { (name, actorID) in
            MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
    }

    /// Get all members (local + remote)
    public func allMembers() -> [MemberInfo] {
        let local = localMembers()
        let remote = state.withLock { Array($0.remoteMembers.values) }
        var members = local
        members.append(contentsOf: remote)
        return members
    }

    /// Find a member by name (searches local + remote)
    /// - Parameter name: The member name to search for
    /// - Returns: MemberInfo if found, nil otherwise
    public func findMember(byName name: String) -> MemberInfo? {
        // First check local
        if let actorID = nameRegistry.find(name: name) {
            return MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
        // Then check remote
        return state.withLock { s in
            s.remoteMembers.values.first { $0.name == name }
        }
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

    // MARK: - Remote Call (Client Side)

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        // Check if local
        if actor.id.peerID == localPeerInfo.peerID {
            return try await executeLocally(
                on: actor,
                target: target,
                invocation: &invocation,
                returning: returning
            )
        }

        // Remote call via routes
        return try await executeRemotely(
            on: actor,
            target: target,
            invocation: &invocation,
            returning: returning
        )
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        // Check if local
        if actor.id.peerID == localPeerInfo.peerID {
            try await executeLocallyVoid(
                on: actor,
                target: target,
                invocation: &invocation
            )
            return
        }

        // Remote call via routes
        try await executeRemotelyVoid(
            on: actor,
            target: target,
            invocation: &invocation
        )
    }

    // MARK: - Local Execution

    private func executeLocally<Act, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Res: Codable {
        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        var decoder = try CodableInvocationDecoder(envelope: envelope)

        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        guard let response = capturedResponse else {
            throw CommunityError.invalidResponse
        }

        switch response.result {
        case .success(let data):
            return try JSONDecoder().decode(Res.self, from: data)
        case .void:
            fatalError("Expected return value but got void")
        case .failure(let error):
            throw error
        }
    }

    private func executeLocallyVoid<Act>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID {
        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        var decoder = try CodableInvocationDecoder(envelope: envelope)

        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        guard let response = capturedResponse else {
            throw CommunityError.invalidResponse
        }

        if case .failure(let error) = response.result {
            throw error
        }
    }

    // MARK: - Remote Execution

    private func executeRemotely<Act, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Res: Codable {
        // Find transport for target peer
        guard let transport = node.transport(for: actor.id.peerID) else {
            throw CommunityError.peerNotFound(actor.id.peerID.value)
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Send invocation and wait for response
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseEnvelope, Error>) in
            // Register pending call
            pendingCalls.withLock { pending in
                pending[envelope.callID] = continuation
            }

            // Send the invocation
            Task {
                do {
                    try await transport.send(.invocation(envelope))
                } catch {
                    // If sending fails, remove pending and resume with error
                    let cont = self.pendingCalls.withLock { pending in
                        pending.removeValue(forKey: envelope.callID)
                    }
                    cont?.resume(throwing: error)
                }
            }
        }

        switch response.result {
        case .success(let resultData):
            return try JSONDecoder().decode(Res.self, from: resultData)
        case .void:
            fatalError("Expected return value but got void")
        case .failure(let error):
            throw error
        }
    }

    private func executeRemotelyVoid<Act>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID {
        // Find transport for target peer
        guard let transport = node.transport(for: actor.id.peerID) else {
            throw CommunityError.peerNotFound(actor.id.peerID.value)
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Send invocation and wait for response
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseEnvelope, Error>) in
            // Register pending call
            pendingCalls.withLock { pending in
                pending[envelope.callID] = continuation
            }

            // Send the invocation
            Task {
                do {
                    try await transport.send(.invocation(envelope))
                } catch {
                    // If sending fails, remove pending and resume with error
                    let cont = self.pendingCalls.withLock { pending in
                        pending.removeValue(forKey: envelope.callID)
                    }
                    cont?.resume(throwing: error)
                }
            }
        }

        if case .failure(let error) = response.result {
            throw error
        }
    }
}
