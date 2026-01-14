import Testing
import Foundation
@testable import CommunityCore

extension SerializedTestSuites {
    /// Integration tests for gRPC-based distributed actor communication
    @Suite("gRPC Integration Tests")
    struct GRPCIntegrationTests {

        @Test("Server starts and stops cleanly")
        func serverStartsAndStops() async throws {
            let system = CommunitySystem(name: "test-server")
            let transport = GRPCTransport(
            configuration: .server(port: 0)
            )

            try await transport.open()
            try await system.start(transport: transport)

            // Verify server is running
            let port = transport.boundPort
            #expect(port != nil)
            #expect(port! > 0)

            try await system.stop()
        }

        @Test("Client connects to server")
        func clientConnectsToServer() async throws {
            // Start server
            let serverSystem = CommunitySystem(name: "server")
            let serverTransport = GRPCTransport(
            configuration: .server(port: 0)
            )
            try await serverTransport.open()
            try await serverSystem.start(transport: serverTransport)

            // Create system actor on server
            _ = serverSystem.createSystemActor()

            guard let serverPort = serverTransport.boundPort else {
                throw CommunityError.systemNotStarted
            }

            // Start client
            let clientSystem = CommunitySystem(name: "client")
            let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
            )
            try await clientTransport.open()
            try await clientSystem.start(transport: clientTransport)

            // Query server's system actor
            let remotePeerID = PeerID("127.0.0.1:\(serverPort)")
            let systemActor = try clientSystem.remoteSystemActor(peerID: remotePeerID)

            // List members (should be empty since we haven't created any)
            let members = try await systemActor.listMembers()
            #expect(members.isEmpty)

            try await clientSystem.stop()
            try await serverSystem.stop()
        }

        @Test("Member registration and discovery")
        func memberRegistrationAndDiscovery() async throws {
            // Start server
            let serverSystem = CommunitySystem(name: "server")
            let serverTransport = GRPCTransport(
            configuration: .server(port: 0)
            )
            try await serverTransport.open()
            try await serverSystem.start(transport: serverTransport)

            // Create system actor
            _ = serverSystem.createSystemActor()

            // Create a member with echo command
            let pty = try PTY(command: "/bin/cat")
            _ = try serverSystem.createMember(name: "test-member", pty: pty, ownsPTY: true)

            guard let serverPort = serverTransport.boundPort else {
                throw CommunityError.systemNotStarted
            }

            // Start client
            let clientSystem = CommunitySystem(name: "client")
            let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
            )
            try await clientTransport.open()
            try await clientSystem.start(transport: clientTransport)

            // Query server's system actor
            let remotePeerID = PeerID("127.0.0.1:\(serverPort)")
            let systemActor = try clientSystem.remoteSystemActor(peerID: remotePeerID)

            // Find member
            let memberID = try await systemActor.findMember(name: "test-member")
            #expect(memberID != nil)

            // List members
            let members = try await systemActor.listMembers()
            #expect(members.count == 1)
            #expect(members.first?.name == "test-member")

            pty.close()
            try await clientSystem.stop()
            try await serverSystem.stop()
        }

        @Test("Tell message to remote member")
        func tellMessageToRemoteMember() async throws {
            // Start server
            let serverSystem = CommunitySystem(name: "server")
            let serverTransport = GRPCTransport(
            configuration: .server(port: 0)
            )
            try await serverTransport.open()
            try await serverSystem.start(transport: serverTransport)

            // Create system actor
            _ = serverSystem.createSystemActor()

            // Create a member with cat command
            let pty = try PTY(command: "/bin/cat")
            _ = try serverSystem.createMember(name: "alice", pty: pty, ownsPTY: true)

            guard let serverPort = serverTransport.boundPort else {
                throw CommunityError.systemNotStarted
            }

            // Start client
            let clientSystem = CommunitySystem(name: "client")
            let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: serverPort)
            )
            try await clientTransport.open()
            try await clientSystem.start(transport: clientTransport)

            // Find member via system actor
            let remotePeerID = PeerID("127.0.0.1:\(serverPort)")
            let systemActor = try clientSystem.remoteSystemActor(peerID: remotePeerID)

            guard let memberID = try await systemActor.findMember(name: "alice") else {
                throw CommunityError.memberNotFound("alice")
            }

            // Resolve member and send message
            let member = try Member.resolve(id: memberID, using: clientSystem)
            try await member.tell("hello world")

            // Wait for the message to be processed
            try await Task.sleep(for: .milliseconds(100))

            // Verify member is running
            let isRunning = try await member.isRunning()
            #expect(isRunning)

            pty.close()
            try await clientSystem.stop()
            try await serverSystem.stop()
        }

        @Test("Connection to non-existent server times out gracefully")
        func connectionToNonExistentServerTimesOut() async throws {
            let clientSystem = CommunitySystem(name: "client")
            let clientTransport = GRPCTransport(
            configuration: .client(host: "127.0.0.1", port: 59999)
            )

            // Start transport and system
            try await clientTransport.open()
            try await clientSystem.start(transport: clientTransport)

            // Attempting to use the transport will fail
            let remotePeerID = PeerID("127.0.0.1:59999")
            let systemActor = try clientSystem.remoteSystemActor(peerID: remotePeerID)

            // This should throw since server doesn't exist
            do {
                _ = try await systemActor.listMembers()
                Issue.record("Expected connection to fail")
            } catch {
                // Expected - connection failed
            }

            try await clientSystem.stop()
        }
    }
}
