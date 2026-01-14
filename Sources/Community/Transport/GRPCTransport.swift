import Foundation
import Discovery
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization

// MARK: - grpc-swift-2 Usage Patterns
//
// This file uses grpc-swift-2 (https://github.com/grpc/grpc-swift-2).
// Key patterns and learnings:
//
// ## Server Lifecycle
// - Create `GRPCServer` with transport and services
// - Call `server.serve()` in a Task - it runs until shutdown
// - Use `server.listeningAddress` to wait for server to be ready (IMPORTANT!)
// - Call `server.beginGracefulShutdown()` to stop
//
// Example:
// ```
// let server = GRPCServer(transport: .http2NIOPosix(...), services: [myService])
// Task { try await server.serve() }
// if let address = try await server.listeningAddress {
//     print("Server listening on \(address)")
// }
// ```
//
// ## Client Lifecycle
// - Create `GRPCClient` with transport
// - MUST call `client.runConnections()` in a background Task before making RPC calls
// - RPCs are queued internally while connection is establishing
// - Call `client.beginGracefulShutdown()` to stop
// - Store and reuse clients - creating new clients for each call is inefficient
//
// Example:
// ```
// let client = GRPCClient(transport: .http2NIOPosix(...))
// Task { try await client.runConnections() }
// // Client is ready for RPC calls (they will queue if connection isn't ready yet)
// let stub = MyService.Client(wrapping: client)
// let response = try await stub.myMethod(request)
// ```
//
// ## Alternative: withGRPCClient / withGRPCServer
// - Scoped helper functions that manage lifecycle automatically
// - Good for short-lived operations, but client is closed when closure returns
// - May have type inference issues with complex return types
//
// ## Server Streaming RPCs
// - Use callback-based API: `stub.method(request) { response in ... }`
// - Access `response.messages` for AsyncSequence of messages
// - Or use `response.accepted` and `contents.bodyParts` for more control
//
// ## Common Pitfalls
// 1. NOT calling `runConnections()` - RPCs will fail
// 2. Creating new clients for each RPC - wasteful, may cause connection issues
// 3. Using `Task.sleep` to wait for connection - use `listeningAddress` for server
// 4. Not storing clients - losing reference causes premature shutdown
//

/// gRPC-based Transport implementation for peer-to-peer communication.
public final class GRPCTransport: Discovery.Transport, @unchecked Sendable {
    // MARK: - Transport Protocol Properties

    public let transportID: String = "community.grpc"
    public let displayName: String = "gRPC Transport"

    public var isActive: Bool {
        get async { state.isActive }
    }

    /// The actual port the server is bound to (for testing)
    public var boundPort: Int? {
        get async { _boundPort.withLock { $0 } }
    }

    /// All registered peer IDs (for testing)
    public var registeredPeers: [Discovery.PeerID] {
        get async { state.allPeerIDs() }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let host: String
        public let port: Int
        public let useTLS: Bool
        public let knownPeers: [PeerEndpoint]
        public let serverEnabled: Bool

        public init(
            host: String = "127.0.0.1",
            port: Int = 50051,
            useTLS: Bool = false,
            knownPeers: [PeerEndpoint] = [],
            serverEnabled: Bool = true
        ) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
            self.knownPeers = knownPeers
            self.serverEnabled = serverEnabled
        }
    }

    public struct PeerEndpoint: Sendable {
        public let peerID: Discovery.PeerID
        public let host: String
        public let port: Int

        public init(peerID: Discovery.PeerID, host: String, port: Int) {
            self.peerID = peerID
            self.host = host
            self.port = port
        }
    }

    /// Local peer information for this transport instance.
    public struct LocalPeerInfo: Sendable {
        public let peerID: Discovery.PeerID
        public let displayName: String?
        public let metadata: [String: String]

        public init(
            peerID: Discovery.PeerID,
            displayName: String? = nil,
            metadata: [String: String] = [:]
        ) {
            self.peerID = peerID
            self.displayName = displayName
            self.metadata = metadata
        }
    }

    // MARK: - Private Properties

    private let localPeerInfo: LocalPeerInfo
    private let config: Configuration
    private let state: GRPCTransportState
    private let dataHandler: DataHandler?

    private var server: GRPCServer<HTTP2ServerTransport.Posix>?
    private var serverTask: Task<Void, Error>?
    private let clients = Mutex<[Discovery.PeerID: GRPCClient<HTTP2ClientTransport.Posix>]>([:])
    private let endpoints = Mutex<[Discovery.PeerID: PeerEndpoint]>([:])
    private let _boundPort = Mutex<Int?>(nil)

    /// Handler for incoming data requests.
    public typealias DataHandler = @Sendable (
        _ data: Data,
        _ from: Discovery.PeerID
    ) async throws -> Data

    // MARK: - Initialization

    public init(
        localPeerInfo: LocalPeerInfo,
        config: Configuration = Configuration(),
        dataHandler: DataHandler? = nil
    ) {
        self.localPeerInfo = localPeerInfo
        self.config = config
        self.state = GRPCTransportState()
        self.dataHandler = dataHandler
    }

    // MARK: - Transport Protocol: Lifecycle

    public func start() async throws {
        guard !state.isActive else {
            throw Discovery.TransportError.alreadyStarted
        }

        state.start()
        print("[GRPCTransport] Starting...")

        // Start gRPC server if enabled
        if config.serverEnabled {
            print("[GRPCTransport] Starting server on \(config.host):\(config.port)...")

            let service = GRPCTransportService(localPeerInfo: localPeerInfo, state: state, dataHandler: dataHandler)
            print("[GRPCTransport] Service created: \(type(of: service))")

            // Create server instance
            let grpcServer = GRPCServer(
                transport: .http2NIOPosix(
                    address: .ipv4(host: config.host, port: config.port),
                    transportSecurity: .plaintext
                ),
                services: [service]
            )
            self.server = grpcServer
            print("[GRPCTransport] Server instance created")

            // Start serve() in a background task
            serverTask = Task {
                do {
                    print("[GRPCTransport] Starting serve()...")
                    try await grpcServer.serve()
                    print("[GRPCTransport] serve() returned normally")
                } catch {
                    print("[GRPCTransport] ✗ Server error: \(error)")
                }
            }

            // Wait for server to be ready by checking listeningAddress
            print("[GRPCTransport] Waiting for server to start listening...")
            if let address = try await grpcServer.listeningAddress {
                print("[GRPCTransport] ✓ Server listening on \(address)")
                // Extract and store the actual bound port
                if let ipv4 = address.ipv4 {
                    _boundPort.withLock { $0 = ipv4.port }
                } else if let ipv6 = address.ipv6 {
                    _boundPort.withLock { $0 = ipv6.port }
                } else {
                    // Fallback to configured port
                    _boundPort.withLock { $0 = config.port }
                }
            } else {
                print("[GRPCTransport] ✗ Server failed to get listening address")
                throw Discovery.TransportError.connectionFailed("Server failed to bind")
            }
        } else {
            print("[GRPCTransport] Client-only mode (no server)")
        }

        // Register self as a peer
        var selfPeerInfo = ProtoPeerInfo()
        selfPeerInfo.peerID = localPeerInfo.peerID.value
        selfPeerInfo.displayName = localPeerInfo.displayName ?? localPeerInfo.peerID.value
        selfPeerInfo.metadata = localPeerInfo.metadata
        state.registerPeer(selfPeerInfo)

        // Connect to known peers
        print("[GRPCTransport] Connecting to \(config.knownPeers.count) known peers...")
        for endpoint in config.knownPeers {
            print("[GRPCTransport] Connecting to \(endpoint.host):\(endpoint.port)...")
            do {
                try await connectToPeer(endpoint)
                print("[GRPCTransport] Connected to \(endpoint.host):\(endpoint.port)")
            } catch {
                print("[GRPCTransport] Failed to connect to \(endpoint.host):\(endpoint.port): \(error)")
            }
        }

        state.emitEvent(.started)
        print("[GRPCTransport] Started")
    }

    public func stop() async throws {
        guard state.isActive else {
            throw Discovery.TransportError.notStarted
        }

        print("[GRPCTransport] Stopping...")
        state.emitEvent(.stopped)
        state.stop()

        // Gracefully shutdown the server
        if let server = server {
            print("[GRPCTransport] Initiating server graceful shutdown...")
            server.beginGracefulShutdown()
        }
        serverTask?.cancel()
        serverTask = nil
        server = nil

        // Close all client connections
        clients.withLock { clients in
            for (_, client) in clients {
                client.beginGracefulShutdown()
            }
            clients.removeAll()
        }
        print("[GRPCTransport] Stopped")
    }

    // MARK: - Transport Protocol: Discovery

    public func discover(timeout: Duration) -> AsyncThrowingStream<Discovery.PeerID, Swift.Error> {
        let capturedState = self.state
        let currentEndpoints: [Discovery.PeerID: PeerEndpoint] = self.endpoints.withLock { $0 }

        print("[GRPCTransport] discover() called, endpoints count: \(currentEndpoints.count)")

        let (stream, continuation) = AsyncThrowingStream<Discovery.PeerID, Swift.Error>.makeStream()

        let discoverTask = Task<Void, Never> { [weak self] in
            var discoveredPeerIDs = Set<Discovery.PeerID>()

            // First, return locally registered peers
            let localPeerIDs = capturedState.allPeerIDs()
            print("[GRPCTransport] Local registered peers: \(localPeerIDs.map { $0.value })")
            for peerID in localPeerIDs {
                if discoveredPeerIDs.insert(peerID).inserted {
                    print("[GRPCTransport] Yielding local peer: \(peerID.value)")
                    continuation.yield(peerID)
                }
            }

            // Query remote peers via gRPC
            if let self = self {
                print("[GRPCTransport] Querying remote peers...")
                let remotePeerIDs = await self.queryRemotePeers(timeout: timeout, endpoints: currentEndpoints)
                print("[GRPCTransport] Remote peers found: \(remotePeerIDs.map { $0.value })")
                for peerID in remotePeerIDs {
                    if discoveredPeerIDs.insert(peerID).inserted {
                        print("[GRPCTransport] Yielding remote peer: \(peerID.value)")
                        continuation.yield(peerID)
                    }
                }
            }

            print("[GRPCTransport] discover() finished")
            continuation.finish()
        }
        _ = discoverTask

        return stream
    }

    // MARK: - Transport Protocol: Resolution

    public func resolve(_ peerID: Discovery.PeerID) async throws -> Discovery.ResolvedPeer? {
        // Check cache first
        if let cached = state.getCachedResolvedPeer(peerID) {
            return cached
        }

        // Check registered peers
        if let peerInfo = state.getRegisteredPeer(peerID) {
            let resolved = Discovery.ResolvedPeer(
                peerID: peerID,
                displayName: peerInfo.displayName,
                metadata: peerInfo.metadata,
                resolvedAt: Date(),
                ttl: .seconds(300)
            )
            state.cacheResolvedPeer(resolved)
            return resolved
        }

        // Try to resolve via gRPC client
        guard let client = try await getOrCreateClient(for: peerID) else {
            return nil
        }

        var request = ProtoResolveRequest()
        request.peerID = peerID.value

        let transportClient = ProtoCommunityTransport.Client(wrapping: client)
        let response = try await transportClient.resolve(request)

        guard response.found else {
            return nil
        }

        let peer = Discovery.ResolvedPeer(
            peerID: Discovery.PeerID(response.peer.peerID),
            displayName: response.peer.displayName,
            metadata: response.peer.metadata,
            resolvedAt: Date(),
            ttl: .seconds(response.ttlSeconds)
        )
        state.cacheResolvedPeer(peer)
        return peer
    }

    // MARK: - Transport Protocol: Communication

    public func send(to peerID: Discovery.PeerID, data: Data, timeout: Duration) async throws -> Data {
        guard let client = try await getOrCreateClient(for: peerID) else {
            throw Discovery.TransportError.resolutionFailed(peerID)
        }

        var request = ProtoSendRequest()
        request.targetPeerID = peerID.value
        request.senderPeerID = localPeerInfo.peerID.value
        request.data = data
        request.timeoutMilliseconds = Int64(timeout.components.seconds * 1000)
        request.requestID = UUID().uuidString

        let transportClient = ProtoCommunityTransport.Client(wrapping: client)
        let response = try await transportClient.send(request)

        if response.success {
            return response.data
        } else {
            throw Discovery.TransportError.connectionFailed(response.errorMessage)
        }
    }

    // MARK: - Transport Protocol: Events

    public var events: AsyncStream<Discovery.TransportEvent> {
        get async {
            AsyncStream { [state] continuation in
                state.setEventContinuation(continuation)
            }
        }
    }

    // MARK: - Private Methods

    private func queryRemotePeers(
        timeout: Duration,
        endpoints: [Discovery.PeerID: PeerEndpoint]
    ) async -> [Discovery.PeerID] {
        var results: [Discovery.PeerID] = []

        print("[GRPCTransport] queryRemotePeers: querying \(endpoints.count) endpoints")
        for (peerID, endpoint) in endpoints {
            print("[GRPCTransport] Querying endpoint \(endpoint.host):\(endpoint.port) for peer: \(peerID.value)")
            do {
                let peerIDs = try await queryPeersFromEndpoint(endpoint, timeout: timeout)
                print("[GRPCTransport] Got \(peerIDs.count) peers from \(peerID.value)")
                results.append(contentsOf: peerIDs)
            } catch {
                print("[GRPCTransport] ✗ Query failed for \(peerID.value): \(error)")
                // Continue with other endpoints on error
            }
        }

        return results
    }

    private func queryPeersFromEndpoint(_ endpoint: PeerEndpoint, timeout: Duration) async throws -> [Discovery.PeerID] {
        // Reuse or create client for this endpoint
        let client = try await createClientForEndpoint(endpoint)

        let transportClient = ProtoCommunityTransport.Client(wrapping: client)
        var request = ProtoDiscoverRequest()
        request.timeoutMilliseconds = Int64(timeout.components.seconds * 1000)

        print("[GRPCTransport] Sending discover request to \(endpoint.host):\(endpoint.port)...")

        // Use the callback-based API for server streaming
        let discoveredPeers: [Discovery.PeerID] = try await transportClient.discover(request) { response in
            var peers: [Discovery.PeerID] = []
            guard case .success(let contents) = response.accepted else {
                print("[GRPCTransport] Discover response not accepted")
                return peers
            }
            print("[GRPCTransport] Processing discover stream...")
            for try await bodyPart in contents.bodyParts {
                switch bodyPart {
                case .message(let protoPeer):
                    print("[GRPCTransport] Discovered peer: \(protoPeer.peerID)")
                    peers.append(Discovery.PeerID(protoPeer.peerID))
                case .trailingMetadata:
                    break
                }
            }
            print("[GRPCTransport] Discover stream completed with \(peers.count) peers")
            return peers
        }

        return discoveredPeers
    }

    private func connectToPeer(_ endpoint: PeerEndpoint) async throws {
        print("[GRPCTransport] === Connecting to \(endpoint.host):\(endpoint.port) ===")

        // Store endpoint for later use
        endpoints.withLock { $0[endpoint.peerID] = endpoint }
        print("[GRPCTransport] Endpoint stored with peerID: \(endpoint.peerID.value)")

        // Create or reuse client
        let client = try await createClientForEndpoint(endpoint)

        // Resolve peer info
        let transportClient = ProtoCommunityTransport.Client(wrapping: client)
        var request = ProtoResolveRequest()
        request.peerID = endpoint.peerID.value
        print("[GRPCTransport] Sending resolve request for: '\(request.peerID)'")

        do {
            let response = try await transportClient.resolve(request)
            print("[GRPCTransport] ✓ Got resolve response: found=\(response.found), peerID='\(response.peer.peerID)', displayName='\(response.peer.displayName)'")

            if response.found {
                let actualPeerID = Discovery.PeerID(response.peer.peerID)
                // Store endpoint with actual peer ID too
                if actualPeerID != endpoint.peerID {
                    endpoints.withLock { $0[actualPeerID] = endpoint }
                    // Also store client with actual peer ID
                    clients.withLock { $0[actualPeerID] = client }
                    print("[GRPCTransport] Endpoint/client also stored with peerID: \(actualPeerID.value)")
                }
                state.registerPeer(response.peer)
                print("[GRPCTransport] ✓ Peer registered: \(actualPeerID.value)")
            } else {
                print("[GRPCTransport] ✗ Peer not found in resolve response")
            }
        } catch {
            print("[GRPCTransport] ✗ Resolve failed: \(error)")
        }
        print("[GRPCTransport] === End connecting to \(endpoint.host):\(endpoint.port) ===")
    }

    private func getOrCreateClient(for peerID: Discovery.PeerID) async throws -> GRPCClient<HTTP2ClientTransport.Posix>? {
        // Check existing clients
        if let existing = clients.withLock({ $0[peerID] }) {
            return existing
        }

        // Try to find endpoint from stored endpoints (discovered peers)
        if let endpoint = endpoints.withLock({ $0[peerID] }) {
            return try await createClientForEndpoint(endpoint)
        }

        // Try to find endpoint from known peers config
        if let endpoint = config.knownPeers.first(where: { $0.peerID == peerID }) {
            return try await createClientForEndpoint(endpoint)
        }

        print("[GRPCTransport] No endpoint found for peerID: \(peerID.value)")
        return nil
    }

    private func createClientForEndpoint(_ endpoint: PeerEndpoint) async throws -> GRPCClient<HTTP2ClientTransport.Posix> {
        // Check if client already exists
        if let existing = clients.withLock({ $0[endpoint.peerID] }) {
            print("[GRPCTransport] Reusing existing client for \(endpoint.host):\(endpoint.port)")
            return existing
        }

        print("[GRPCTransport] Creating new client for \(endpoint.host):\(endpoint.port)")
        let clientTransport: HTTP2ClientTransport.Posix = try .http2NIOPosix(
            target: .ipv4(address: endpoint.host, port: endpoint.port),
            transportSecurity: .plaintext
        )

        let client = GRPCClient(transport: clientTransport)

        // Store client first, then start runConnections
        clients.withLock { $0[endpoint.peerID] = client }

        // Start runConnections in background task
        Task {
            do {
                try await client.runConnections()
            } catch {
                print("[GRPCTransport] Client runConnections error for \(endpoint.peerID.value): \(error)")
            }
        }

        return client
    }
}

// MARK: - gRPC Service Implementation

struct GRPCTransportService: ProtoCommunityTransport.SimpleServiceProtocol {
    let localPeerInfo: GRPCTransport.LocalPeerInfo
    let state: GRPCTransportState
    let dataHandler: GRPCTransport.DataHandler?

    init(localPeerInfo: GRPCTransport.LocalPeerInfo, state: GRPCTransportState, dataHandler: GRPCTransport.DataHandler?) {
        self.localPeerInfo = localPeerInfo
        self.state = state
        self.dataHandler = dataHandler
        print("[GRPCService] ★★★ Service initialized for peer: \(localPeerInfo.peerID.value) ★★★")
    }

    func discover(
        request: ProtoDiscoverRequest,
        response: RPCWriter<ProtoDiscoveredPeerID>,
        context: ServerContext
    ) async throws {
        print("[GRPCService] ► discover() called")
        let peerIDs = state.allPeerIDs()
        print("[GRPCService] Returning \(peerIDs.count) peers")

        for peerID in peerIDs {
            var protoPeer = ProtoDiscoveredPeerID()
            protoPeer.peerID = peerID.value
            print("[GRPCService] Yielding peer: \(peerID.value)")
            try await response.write(protoPeer)
        }
        print("[GRPCService] ◄ discover() completed")
    }

    func resolve(request: ProtoResolveRequest, context: ServerContext) async throws -> ProtoResolveResponse {
        print("[GRPCService] ► resolve() called for peerID: '\(request.peerID)'")
        print("[GRPCService] Local peerID: '\(localPeerInfo.peerID.value)'")
        var response = ProtoResolveResponse()

        if request.peerID == localPeerInfo.peerID.value {
            print("[GRPCService] Match: local peer")
            response.found = true
            response.peer = createPeerInfo(from: localPeerInfo)
            response.ttlSeconds = 300
        } else if let peerInfo = state.getRegisteredPeer(Discovery.PeerID(request.peerID)) {
            print("[GRPCService] Match: registered peer")
            response.found = true
            response.peer = peerInfo
            response.ttlSeconds = 300
        } else {
            print("[GRPCService] No exact match, returning local peer info")
            // Return local peer info so client can discover us
            response.found = true
            response.peer = createPeerInfo(from: localPeerInfo)
            response.ttlSeconds = 300
        }

        print("[GRPCService] ◄ resolve() returning: found=\(response.found), peerID='\(response.peer.peerID)', displayName='\(response.peer.displayName)'")
        return response
    }

    func send(request: ProtoSendRequest, context: ServerContext) async throws -> ProtoSendResponse {
        print("[GRPCService] ► send() called from '\(request.senderPeerID)' to '\(request.targetPeerID)'")
        var response = ProtoSendResponse()

        guard let handler = dataHandler else {
            print("[GRPCService] ✗ No data handler registered")
            response.success = false
            response.errorMessage = "No data handler registered"
            return response
        }

        guard !request.senderPeerID.isEmpty else {
            print("[GRPCService] ✗ Missing senderPeerID")
            response.success = false
            response.errorMessage = "Missing senderPeerID"
            return response
        }

        let fromPeerID = Discovery.PeerID(request.senderPeerID)

        do {
            print("[GRPCService] Invoking data handler with \(request.data.count) bytes...")
            let resultData = try await handler(request.data, fromPeerID)
            print("[GRPCService] ✓ Handler returned \(resultData.count) bytes")
            response.success = true
            response.data = resultData
        } catch {
            print("[GRPCService] ✗ Handler error: \(error)")
            response.success = false
            response.errorMessage = error.localizedDescription
        }

        print("[GRPCService] ◄ send() returning success=\(response.success)")
        return response
    }

    func subscribe(
        request: ProtoSubscribeRequest,
        response: RPCWriter<ProtoTransportEvent>,
        context: ServerContext
    ) async throws {
        // Placeholder for event streaming
    }

    func register(request: ProtoRegisterRequest, context: ServerContext) async throws -> ProtoRegisterResponse {
        var response = ProtoRegisterResponse()

        guard request.hasPeer else {
            response.success = false
            response.message = "No peer information provided"
            return response
        }

        state.registerPeer(request.peer)
        response.success = true
        response.message = "Peer registered successfully"
        return response
    }

    func heartbeat(request: ProtoHeartbeatRequest, context: ServerContext) async throws -> ProtoHeartbeatResponse {
        var response = ProtoHeartbeatResponse()
        response.acknowledged = true
        response.serverTimestampUnix = Int64(Date().timeIntervalSince1970)
        return response
    }

    private func createPeerInfo(from peer: GRPCTransport.LocalPeerInfo) -> ProtoPeerInfo {
        var info = ProtoPeerInfo()
        info.peerID = peer.peerID.value
        info.displayName = peer.displayName ?? peer.peerID.value
        info.metadata = peer.metadata
        return info
    }
}
