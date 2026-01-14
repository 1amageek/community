import Foundation
import Distributed
import Synchronization
import ActorRuntime
@_exported import Discovery

/// Error types for CommunitySystem
public enum CommunityError: Error, Sendable {
    case systemNotStarted
    case memberNotFound(String)
    case invocationFailed(String)
    case invalidResponse
    case nameAlreadyTaken(String)
}

/// Standard error codes for invocation failures
public enum CommunityErrorCode: UInt32, Sendable {
    case unknown = 0
    case invalidMessage = 1
    case invocationFailed = 2
    case resourceUnavailable = 3
}

/// Distributed actor system for the Community project
///
/// Bridges swift-actor-runtime with swift-discovery to enable
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

    /// Transport coordinator for network communication
    public let coordinator: TransportCoordinator

    /// Local peer information
    public let localPeerInfo: GRPCTransport.LocalPeerInfo

    /// Thread-safe lifecycle state
    private struct LifecycleState {
        var isStarted: Bool = false
    }
    private let lifecycleState = Mutex(LifecycleState())

    // MARK: - Initialization

    /// Create a new CommunitySystem
    /// - Parameter name: The name for this peer (defaults to hostname)
    public init(name: String? = nil) {
        let peerName = name ?? ProcessInfo.processInfo.hostName

        // Initialize local peer info
        self.localPeerInfo = GRPCTransport.LocalPeerInfo(
            peerID: PeerID(peerName),
            displayName: peerName,
            metadata: [:]
        )

        // Initialize registries and coordinator
        self.registry = ActorRegistry()
        self.nameRegistry = NameRegistry()
        self.coordinator = TransportCoordinator(localPeerInfo: localPeerInfo)
    }

    // MARK: - Data Handler for Remote Invocations

    /// Creates a data handler that processes incoming remote invocations.
    ///
    /// This handler should be passed to GRPCTransport when creating it.
    /// It parses incoming InvocationEnvelopes, executes the distributed target
    /// on local actors, and returns the ResponseEnvelope.
    public func makeDataHandler() -> GRPCTransport.DataHandler {
        return { [weak self] (data: Data, from: Discovery.PeerID) async throws -> Data in
            guard let self = self else {
                throw CommunityError.systemNotStarted
            }
            return try await self.handleIncomingData(data, from: from)
        }
    }

    /// Handle incoming data from remote peers
    private func handleIncomingData(_ data: Data, from senderPeerID: Discovery.PeerID) async throws -> Data {
        // Try to decode as InvocationEnvelope first
        if let envelope = try? JSONDecoder().decode(InvocationEnvelope.self, from: data) {
            return try await handleInvocationEnvelope(envelope, from: senderPeerID)
        }

        // Try to decode as MemberQuery
        if let query = try? JSONDecoder().decode(MemberQuery.self, from: data) {
            return try await handleMemberQuery(query, from: senderPeerID)
        }

        throw CommunityError.invocationFailed("Unknown message format")
    }

    /// Handle an incoming invocation envelope
    private func handleInvocationEnvelope(_ envelope: InvocationEnvelope, from senderPeerID: Discovery.PeerID) async throws -> Data {
        // Find the target actor by UUID
        guard let targetActor = registry.find(id: envelope.recipientID) else {
            let errorResponse = ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(RuntimeError.actorNotFound(envelope.recipientID))
            )
            return try JSONEncoder().encode(errorResponse)
        }

        // Create the invocation decoder
        var decoder = try CodableInvocationDecoder(envelope: envelope)

        // Create a result handler to capture the response
        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        // Execute the distributed target
        let target = RemoteCallTarget(envelope.target)
        do {
            try await executeDistributedTarget(
                on: targetActor,
                target: target,
                invocationDecoder: &decoder,
                handler: handler
            )
        } catch {
            let runtimeError: RuntimeError
            if let re = error as? RuntimeError {
                runtimeError = re
            } else {
                runtimeError = RuntimeError.executionFailed(envelope.target, underlying: error.localizedDescription)
            }
            let errorResponse = ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(runtimeError)
            )
            return try JSONEncoder().encode(errorResponse)
        }

        // Return the response
        guard let response = capturedResponse else {
            let errorResponse = ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(RuntimeError.executionFailed(envelope.target, underlying: "No response captured"))
            )
            return try JSONEncoder().encode(errorResponse)
        }

        return try JSONEncoder().encode(response)
    }

    /// Handle member query requests
    private func handleMemberQuery(_ query: MemberQuery, from senderPeerID: Discovery.PeerID) async throws -> Data {
        switch query.type {
        case .listMembers:
            var members: [MemberInfo] = []
            for (name, actorID) in nameRegistry.allEntries() {
                members.append(MemberInfo(
                    name: name,
                    actorID: actorID,
                    peerID: localPeerInfo.peerID,
                    transport: "grpc"
                ))
            }
            let response = MemberListResponse(members: members)
            return try JSONEncoder().encode(response)

        case .findMemberByName:
            guard let name = query.name else {
                let response = FindMemberResponse(found: false, actorID: nil, name: nil)
                return try JSONEncoder().encode(response)
            }
            if let actorID = nameRegistry.find(name: name) {
                let response = FindMemberResponse(found: true, actorID: actorID, name: name)
                return try JSONEncoder().encode(response)
            } else {
                let response = FindMemberResponse(found: false, actorID: nil, name: nil)
                return try JSONEncoder().encode(response)
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the system with the given transports
    public func start(transports: [any Transport]) async throws {
        // Check and set started state atomically
        let alreadyStarted = lifecycleState.withLock { state -> Bool in
            if state.isStarted {
                return true
            }
            state.isStarted = true
            return false
        }
        guard !alreadyStarted else { return }

        // Register transports
        for transport in transports {
            await coordinator.register(transport)
        }

        // Start all transports
        try await coordinator.startAll()
    }

    /// Stop the system
    public func stop() async throws {
        // Check and clear started state atomically
        let wasStarted = lifecycleState.withLock { state -> Bool in
            if !state.isStarted {
                return false
            }
            state.isStarted = false
            return true
        }
        guard wasStarted else { return }

        try await coordinator.stopAll()
        registry.clear()
        nameRegistry.clear()
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
        CommunityActorID(peerID: localPeerInfo.peerID)
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

        // Remote call
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

        // Remote call
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
        // Record target (doneRecording is already called by Swift's distributed actor runtime)
        invocation.recordTarget(target)

        // Create envelope
        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Find local actor by UUID
        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        // Create decoder
        var decoder = try CodableInvocationDecoder(envelope: envelope)

        // Create result handler
        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        // Execute
        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        // Process result
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
        // Record target (doneRecording is already called by Swift's distributed actor runtime)
        invocation.recordTarget(target)

        // Create envelope
        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Find local actor by UUID
        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        // Create decoder
        var decoder = try CodableInvocationDecoder(envelope: envelope)

        // Create result handler
        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        // Execute
        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        // Check that handler was called
        guard let response = capturedResponse else {
            throw CommunityError.invalidResponse
        }

        // Check for errors
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
        // Record target (doneRecording is already called by Swift's distributed actor runtime)
        invocation.recordTarget(target)

        // Create envelope
        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Serialize envelope
        let envelopeData = try JSONEncoder().encode(envelope)

        // Send via TransportCoordinator
        let responseData = try await coordinator.send(
            to: actor.id.peerID,
            data: envelopeData,
            timeout: .seconds(30)
        )

        // Decode ResponseEnvelope
        let response = try JSONDecoder().decode(ResponseEnvelope.self, from: responseData)

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
        // Record target (doneRecording is already called by Swift's distributed actor runtime)
        invocation.recordTarget(target)

        // Create envelope
        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Serialize envelope
        let envelopeData = try JSONEncoder().encode(envelope)

        // Send via TransportCoordinator
        let responseData = try await coordinator.send(
            to: actor.id.peerID,
            data: envelopeData,
            timeout: .seconds(30)
        )

        // Decode ResponseEnvelope and check for errors
        let response = try JSONDecoder().decode(ResponseEnvelope.self, from: responseData)

        if case .failure(let error) = response.result {
            throw error
        }
    }

    // MARK: - Member Query Protocol

    /// Query type identifiers
    private enum QueryType: String, Codable {
        case listMembers = "community.query.listMembers"
        case findMemberByName = "community.query.findMemberByName"
    }

    /// Query request
    private struct MemberQuery: Codable {
        let type: QueryType
        let name: String?  // For findMemberByName
    }

    /// Query response for member list
    private struct MemberListResponse: Codable {
        let members: [MemberInfo]
    }

    /// Query response for find member
    private struct FindMemberResponse: Codable {
        let found: Bool
        let actorID: CommunityActorID?
        let name: String?
    }

    // MARK: - Member Discovery

    /// Find a member by name across all networks
    /// - Parameters:
    ///   - name: The member name to search for
    ///   - timeout: Discovery timeout in seconds (default: 3)
    public func findMember(name: String, timeout: Int = 3) async throws -> CommunityActorID? {
        // First check locally
        if let actorID = nameRegistry.find(name: name) {
            return actorID
        }

        // Query remote peers
        let discoveryStream = await coordinator.discover(timeout: .seconds(timeout))
        for try await peerID in discoveryStream {
            // Skip self
            if peerID == localPeerInfo.peerID {
                continue
            }

            // Query this peer for the member
            if let actorID = try await queryPeerForMember(name: name, on: peerID) {
                return actorID
            }
        }

        return nil
    }

    /// Query a specific peer for a member by name
    private func queryPeerForMember(name: String, on peerID: PeerID) async throws -> CommunityActorID? {
        let query = MemberQuery(type: .findMemberByName, name: name)
        let queryData = try JSONEncoder().encode(query)

        let responseData = try await coordinator.send(
            to: peerID,
            data: queryData,
            timeout: .seconds(5)
        )

        let response = try JSONDecoder().decode(FindMemberResponse.self, from: responseData)
        return response.actorID
    }

    /// Discover all members across all networks
    /// - Parameter timeout: Discovery timeout in seconds (default: 3)
    public func discoverMembers(timeout: Int = 3) async throws -> [MemberInfo] {
        var members: [MemberInfo] = []

        // Add local members
        for (name, actorID) in nameRegistry.allEntries() {
            members.append(MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            ))
        }

        // Query remote peers
        let discoveryStream = await coordinator.discover(timeout: .seconds(timeout))
        for try await peerID in discoveryStream {
            // Skip self
            if peerID == localPeerInfo.peerID {
                continue
            }

            // Query this peer for all members
            if let remoteMembers = try await queryPeerForAllMembers(on: peerID) {
                members.append(contentsOf: remoteMembers)
            }
        }

        return members
    }

    /// Query a specific peer for all members
    private func queryPeerForAllMembers(on peerID: PeerID) async throws -> [MemberInfo]? {
        let query = MemberQuery(type: .listMembers, name: nil)
        let queryData = try JSONEncoder().encode(query)

        let responseData = try await coordinator.send(
            to: peerID,
            data: queryData,
            timeout: .seconds(5)
        )

        let response = try JSONDecoder().decode(MemberListResponse.self, from: responseData)
        return response.members
    }
}

// MARK: - Supporting Types

/// Information about a discovered member
public struct MemberInfo: Sendable, Codable {
    public let name: String
    public let actorID: CommunityActorID
    public let peerID: PeerID
    public let transport: String

    public init(name: String, actorID: CommunityActorID, peerID: PeerID, transport: String = "local") {
        self.name = name
        self.actorID = actorID
        self.peerID = peerID
        self.transport = transport
    }
}

// MARK: - Name Registry

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
