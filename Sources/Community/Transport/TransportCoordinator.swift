import Foundation
import Discovery

/// Coordinates multiple transports for unified peer discovery and communication.
///
/// TransportCoordinator aggregates results from all registered transports, allowing
/// applications to discover and communicate with peers regardless of the underlying transport.
public actor TransportCoordinator {
    /// Registered transports
    private var transports: [String: any Discovery.Transport] = [:]

    /// Local peer information
    public let localPeerInfo: GRPCTransport.LocalPeerInfo

    /// Event listener tasks
    private var eventListenerTasks: [String: Task<Void, Never>] = [:]

    public init(localPeerInfo: GRPCTransport.LocalPeerInfo) {
        self.localPeerInfo = localPeerInfo
    }

    // MARK: - Transport Management

    /// Register a transport
    public func register(_ transport: any Discovery.Transport) {
        transports[transport.transportID] = transport
    }

    /// Unregister a transport
    public func unregister(_ transportID: String) {
        transports.removeValue(forKey: transportID)
    }

    /// Get a specific transport
    public func transport(_ transportID: String) -> (any Discovery.Transport)? {
        transports[transportID]
    }

    /// All registered transports
    public var allTransports: [any Discovery.Transport] {
        Array(transports.values)
    }

    // MARK: - Lifecycle

    /// Start all transports
    public func startAll() async throws {
        for transport in transports.values {
            try await transport.start()
            startEventListener(for: transport)
        }
    }

    /// Stop all transports
    public func stopAll() async throws {
        for task in eventListenerTasks.values {
            task.cancel()
        }
        eventListenerTasks.removeAll()

        for transport in transports.values {
            try await transport.stop()
        }
    }

    // MARK: - Event Handling

    /// Start listening for events from a transport
    private func startEventListener(for transport: any Discovery.Transport) {
        let transportID = transport.transportID

        let task = Task { [weak self] in
            for await event in await transport.events {
                guard let self = self else { break }
                await self.handleEvent(event, from: transportID)
            }
        }

        eventListenerTasks[transportID] = task
    }

    /// Handle an event from a transport
    private func handleEvent(_ event: Discovery.TransportEvent, from transportID: String) async {
        switch event {
        case .peerDiscovered:
            break
        case .peerLost:
            break
        case .messageReceived:
            break
        case .error:
            break
        default:
            break
        }
    }

    // MARK: - Resolution (across all transports)

    /// Resolve a peer across all transports
    public func resolve(_ peerID: Discovery.PeerID) async throws -> Discovery.ResolvedPeer? {
        for transport in transports.values {
            if let resolved = try await transport.resolve(peerID) {
                return resolved
            }
        }
        return nil
    }

    // MARK: - Discovery (across all transports)

    /// Discover all peers across all transports
    public func discover(
        timeout: Duration = .seconds(5)
    ) -> AsyncThrowingStream<Discovery.PeerID, Error> {
        let capturedTransports = Array(transports.values)

        return AsyncThrowingStream { continuation in
            Task {
                var discoveredPeerIDs = Set<Discovery.PeerID>()

                for transport in capturedTransports {
                    do {
                        for try await peerID in transport.discover(timeout: timeout) {
                            // Avoid duplicates
                            if discoveredPeerIDs.insert(peerID).inserted {
                                continuation.yield(peerID)
                            }
                        }
                    } catch {
                        // Continue with other transports
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Communication

    /// Send data to a peer using best available transport
    public func send(
        to peerID: Discovery.PeerID,
        data: Data,
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        // Find an active transport to send
        for transport in transports.values {
            do {
                return try await transport.send(
                    to: peerID,
                    data: data,
                    timeout: timeout
                )
            } catch {
                // Try next transport
                continue
            }
        }

        throw Discovery.TransportError.connectionFailed("No transport available")
    }
}
