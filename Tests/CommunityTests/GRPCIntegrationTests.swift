import Testing
import Foundation
import Discovery
@testable import Community

/// Integration tests for gRPC-based distributed actor communication
///
/// These tests verify that the full communication stack works correctly:
/// - Server startup and client connection
/// - Member discovery across peers
/// - Distributed method invocation (tell)
@Suite("gRPC Integration Tests")
struct GRPCIntegrationTests {

    // MARK: - Server/Client Connection Tests

    @Test("Server starts and client can connect")
    func serverStartsAndClientConnects() async throws {
        // Start server on random port
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])

        // Get the actual bound port
        let serverPort = await serverTransport.boundPort
        #expect(serverPort != nil, "Server should bind to a port")
        #expect(serverPort! > 0, "Server port should be valid")

        // Start client connecting to server
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort!
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Cleanup
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    @Test("Client discovers server peer via resolve")
    func clientDiscoversPeerViaResolve() async throws {
        // Start server
        let serverSystem = CommunitySystem(name: "server-peer")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        // Start client
        let clientSystem = CommunitySystem(name: "client-peer")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("initial-peer"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Verify client can see the server peer
        let discoveredPeers = await clientTransport.registeredPeers
        #expect(discoveredPeers.contains(where: { $0.value == "server-peer" }),
                "Client should discover server peer")

        // Cleanup
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    // MARK: - Member Discovery Tests

    @Test("Client discovers members on server")
    func clientDiscoversMembersOnServer() async throws {
        // Start server with a member
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        // Create a member on server (using /bin/cat which just echoes)
        let pty = try PTY(command: "/bin/cat")
        _ = try serverSystem.createMember(name: "test-member", pty: pty)

        // Start client
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Discover members
        let members = try await clientSystem.discoverMembers(timeout: 3)

        #expect(members.contains(where: { $0.name == "test-member" }),
                "Client should discover 'test-member' on server")

        // Cleanup
        pty.close()
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    @Test("Client finds specific member by name")
    func clientFindsSpecificMemberByName() async throws {
        // Start server with a member
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        let pty = try PTY(command: "/bin/cat")
        let serverMember = try serverSystem.createMember(name: "alice", pty: pty)

        // Start client
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Find specific member
        let foundID = try await clientSystem.findMember(name: "alice", timeout: 3)

        #expect(foundID != nil, "Client should find 'alice'")
        #expect(foundID?.id == serverMember.id.id, "Found ID should match server member's ID")

        // Cleanup
        pty.close()
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    // MARK: - Distributed Method Invocation Tests

    @Test("Client can invoke tell on remote member")
    func clientCanInvokeTellOnRemoteMember() async throws {
        // Start server with a member
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        // Use /bin/cat which just buffers input
        let pty = try PTY(command: "/bin/cat")
        _ = try serverSystem.createMember(name: "bob", pty: pty)

        // Start client
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Find member and invoke tell
        guard let memberID = try await clientSystem.findMember(name: "bob", timeout: 3) else {
            Issue.record("Failed to find member 'bob'")
            pty.close()
            try await clientSystem.stop()
            try await serverSystem.stop()
            return
        }

        // Resolve the remote member and call tell
        let member = try Member.resolve(id: memberID, using: clientSystem)
        try await member.tell("Hello from client")

        // Give PTY time to process
        try await Task.sleep(for: .milliseconds(100))

        // Verify message was written (check PTY received it)
        // Note: In real usage, the message would appear in the PTY output
        // For testing, we just verify no exception was thrown

        // Cleanup
        pty.close()
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    @Test("Remote getName call returns correct value")
    func remoteGetNameReturnsCorrectValue() async throws {
        // Start server with a member
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        let pty = try PTY(command: "/bin/cat")
        _ = try serverSystem.createMember(name: "charlie", pty: pty)

        // Start client
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Find and call getName
        guard let memberID = try await clientSystem.findMember(name: "charlie", timeout: 3) else {
            Issue.record("Failed to find member 'charlie'")
            pty.close()
            try await clientSystem.stop()
            try await serverSystem.stop()
            return
        }

        let member = try Member.resolve(id: memberID, using: clientSystem)
        let name = try await member.getName()

        #expect(name == "charlie", "Remote getName should return 'charlie'")

        // Cleanup
        pty.close()
        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    // MARK: - Error Handling Tests

    @Test("Connection to non-existent server times out gracefully")
    func connectionToNonExistentServerTimesOut() async throws {
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("nonexistent"),
                        host: "127.0.0.1",
                        port: 59999  // Unlikely to be in use
                    )
                ],
                serverEnabled: false
            )
        )

        // Should not throw, just fail to connect
        try await clientSystem.start(transports: [clientTransport])

        // Discovery should return empty or timeout
        let members = try await clientSystem.discoverMembers(timeout: 1)
        // May or may not find local members, but should not crash

        try await clientSystem.stop()
    }

    @Test("Finding non-existent member returns nil")
    func findingNonExistentMemberReturnsNil() async throws {
        // Start server without any members
        let serverSystem = CommunitySystem(name: "server")
        let serverTransport = GRPCTransport(
            localPeerInfo: serverSystem.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: serverSystem.makeDataHandler()
        )

        try await serverSystem.start(transports: [serverTransport])
        let serverPort = await serverTransport.boundPort!

        // Start client
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server"),
                        host: "127.0.0.1",
                        port: serverPort
                    )
                ],
                serverEnabled: false
            )
        )

        try await clientSystem.start(transports: [clientTransport])

        // Try to find non-existent member
        let foundID = try await clientSystem.findMember(name: "nonexistent", timeout: 1)

        #expect(foundID == nil, "Should not find non-existent member")

        try await clientSystem.stop()
        try await serverSystem.stop()
    }

    // MARK: - Multiple Peers Tests

    @Test("Discovery finds members across multiple peers")
    func discoveryFindsAcrossMultiplePeers() async throws {
        // Start server 1
        let server1System = CommunitySystem(name: "server1")
        let server1Transport = GRPCTransport(
            localPeerInfo: server1System.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: server1System.makeDataHandler()
        )
        try await server1System.start(transports: [server1Transport])
        let server1Port = await server1Transport.boundPort!

        let pty1 = try PTY(command: "/bin/cat")
        _ = try server1System.createMember(name: "member1", pty: pty1)

        // Start server 2
        let server2System = CommunitySystem(name: "server2")
        let server2Transport = GRPCTransport(
            localPeerInfo: server2System.localPeerInfo,
            config: GRPCTransport.Configuration(port: 0, serverEnabled: true),
            dataHandler: server2System.makeDataHandler()
        )
        try await server2System.start(transports: [server2Transport])
        let server2Port = await server2Transport.boundPort!

        let pty2 = try PTY(command: "/bin/cat")
        _ = try server2System.createMember(name: "member2", pty: pty2)

        // Start client connecting to both servers
        let clientSystem = CommunitySystem(name: "client")
        let clientTransport = GRPCTransport(
            localPeerInfo: clientSystem.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server1"),
                        host: "127.0.0.1",
                        port: server1Port
                    ),
                    GRPCTransport.PeerEndpoint(
                        peerID: PeerID("server2"),
                        host: "127.0.0.1",
                        port: server2Port
                    )
                ],
                serverEnabled: false
            )
        )
        try await clientSystem.start(transports: [clientTransport])

        // Discover all members
        let members = try await clientSystem.discoverMembers(timeout: 3)
        let memberNames = members.map { $0.name }

        #expect(memberNames.contains("member1"), "Should find member1 from server1")
        #expect(memberNames.contains("member2"), "Should find member2 from server2")

        // Cleanup
        pty1.close()
        pty2.close()
        try await clientSystem.stop()
        try await server2System.stop()
        try await server1System.stop()
    }
}
