import ArgumentParser
import CommunityCore
import Foundation

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

        // Create and start gRPC transport in client mode
        let transport = GRPCTransport(
            configuration: .client(host: host, port: port)
        )

        print("Connecting to \(host):\(port)...")
        try await transport.open()

        // Start the system
        try await system.start(transport: transport)
        print("Connected.")

        // Get remote system actor to find the member
        let remotePeerID = PeerID("\(host):\(port)")
        let systemActor = try system.remoteSystemActor(peerID: remotePeerID)

        print("Looking for member '\(name)'...")

        // Find the member
        guard let memberID = try await systemActor.findMember(name: name) else {
            print("Member '\(name)' not found")
            try await system.stop()
            throw ExitCode.failure
        }

        print("Found member: \(memberID)")

        // Resolve and call the member
        do {
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
