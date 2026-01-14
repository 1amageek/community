import Foundation

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
