import ArgumentParser
import Foundation
import Discovery

/// Send a message to a member
public struct TellCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tell",
        abstract: "Send a message to a member"
    )

    @Argument(help: "Target member name")
    var name: String

    @Argument(help: "Message to send")
    var message: String

    @Option(name: .shortAndLong, help: "Target peer host")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Target peer port")
    var port: Int = 50051

    public init() {}

    public func run() async throws {
        // Create the actor system
        let system = CommunitySystem()

        // Create gRPC transport with known peer
        let knownPeer = GRPCTransport.PeerEndpoint(
            peerID: PeerID(name),
            host: host,
            port: port
        )
        print("Connecting to peer '\(name)' at \(host):\(port)...")

        let transport = GRPCTransport(
            localPeerInfo: system.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: [knownPeer],
                serverEnabled: false  // Client-only mode
            )
        )

        // Start the system
        do {
            try await system.start(transports: [transport])
            print("System started")
        } catch {
            print("Failed to start system: \(error)")
            throw error
        }

        // Find the member
        print("Looking for member '\(name)'...")

        guard let memberID = try await system.findMember(name: name) else {
            print("Member '\(name)' not found")
            try await system.stop()
            throw ExitCode.failure
        }

        // Resolve and call the member
        do {
            // Create a proxy to the remote member
            let member = try Member.resolve(id: memberID, using: system)
            try await member.tell(message)
            print("Sent to '\(name)': \(message)")
        } catch {
            print("Failed to send message: \(error)")
            try await system.stop()
            throw ExitCode.failure
        }

        try await system.stop()
    }
}
