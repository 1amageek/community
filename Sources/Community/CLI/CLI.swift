import ArgumentParser
import Foundation

/// Main CLI command for the community member management tool
@main
public struct MM: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mm",
        abstract: "Community member management CLI",
        discussion: """
        Manage distributed members across networks.

        Each member runs a command in a PTY (pseudo-terminal) and can receive
        messages from other members on the network.
        """,
        subcommands: [
            JoinCommand.self,
            TellCommand.self,
            LeaveCommand.self,
            ListCommand.self
        ],
        defaultSubcommand: ListCommand.self
    )

    public init() {}
}
