import Foundation
import Distributed
import Synchronization
import Peer
import PeerGRPC
import ActorRuntime

/// Distributed actor system for the Community project
///
/// Bridges swift-actor-runtime with swift-peer to enable
/// distributed actor communication across networks.
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

    /// Transport for network communication
    private var transport: (any DistributedTransport)?

    /// Local peer information
    public let localPeerInfo: PeerInfo

    /// Thread-safe lifecycle state
    private struct LifecycleState {
        var isStarted: Bool = false
        var invocationTask: Task<Void, Never>?
    }
    private let lifecycleState = Mutex(LifecycleState())

    // MARK: - Initialization

    /// Create a new CommunitySystem
    /// - Parameter name: The name for this peer (defaults to hostname)
    public init(name: String? = nil) {
        let peerName = name ?? ProcessInfo.processInfo.hostName

        // Initialize local peer info
        self.localPeerInfo = PeerInfo(
            peerID: PeerID(peerName),
            displayName: peerName
        )

        // Initialize registries
        self.registry = ActorRegistry()
        self.nameRegistry = NameRegistry()
    }

    // MARK: - Lifecycle

    /// Start the system with the given transport
    public func start(transport: any DistributedTransport) async throws {
        // Check and set started state atomically
        let alreadyStarted = lifecycleState.withLock { state -> Bool in
            if state.isStarted {
                return true
            }
            state.isStarted = true
            return false
        }
        guard !alreadyStarted else { return }

        self.transport = transport

        // Start processing incoming invocations
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.processIncomingInvocations()
        }

        lifecycleState.withLock { state in
            state.invocationTask = task
        }
    }

    /// Stop the system
    public func stop() async throws {
        // Check and clear started state atomically
        let (wasStarted, task) = lifecycleState.withLock { state -> (Bool, Task<Void, Never>?) in
            if !state.isStarted {
                return (false, nil)
            }
            state.isStarted = false
            let task = state.invocationTask
            state.invocationTask = nil
            return (true, task)
        }
        guard wasStarted else { return }

        // Cancel the invocation processing task
        task?.cancel()

        // Close the transport
        try await transport?.close()
        transport = nil

        registry.clear()
        nameRegistry.clear()
    }

    // MARK: - Incoming Invocation Processing

    private func processIncomingInvocations() async {
        guard let transport = self.transport else { return }

        do {
            for try await envelope in transport.incomingInvocations {
                let response = await handleInvocation(envelope)
                try await transport.sendResponse(response)
            }
        } catch {
            // Stream ended or error occurred
        }
    }

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

        // Remote call via transport
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

        // Remote call via transport
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
        guard let transport = self.transport else {
            throw CommunityError.systemNotStarted
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        let response = try await transport.sendInvocation(envelope)

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
        guard let transport = self.transport else {
            throw CommunityError.systemNotStarted
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        let response = try await transport.sendInvocation(envelope)

        if case .failure(let error) = response.result {
            throw error
        }
    }
}
