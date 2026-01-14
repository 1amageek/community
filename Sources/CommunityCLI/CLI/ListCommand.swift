import ArgumentParser
import CommunityCore
import Foundation

/// List all members in the community
public struct ListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List members on a remote peer"
    )

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

        // Get remote system actor to list members
        let remotePeerID = PeerID("\(host):\(port)")
        let systemActor = try system.remoteSystemActor(peerID: remotePeerID)

        // Get members from remote peer
        let members = try await systemActor.listMembers()

        if members.isEmpty {
            print("No members registered")
        } else {
            // Print header
            print("\("NAME".padding(toLength: 20, withPad: " ", startingAt: 0))\("PEER".padding(toLength: 20, withPad: " ", startingAt: 0))")
            print(String(repeating: "-", count: 40))

            // Print members
            for member in members {
                let name = member.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                let peer = member.peerID.value.padding(toLength: 20, withPad: " ", startingAt: 0)
                print("\(name)\(peer)")
            }
        }

        try await system.stop()
    }
}
