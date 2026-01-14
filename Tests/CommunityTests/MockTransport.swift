import Foundation
import Peer
import ActorRuntime
@testable import CommunityCore

/// テスト用モックDistributedTransport
final class MockDistributedTransport: DistributedTransport, @unchecked Sendable {
    private let state = MockTransportState()

    // MARK: - DistributedTransport Protocol

    func sendInvocation(_ envelope: InvocationEnvelope) async throws -> ResponseEnvelope {
        await state.recordSendInvocation()
        // Return a void response by default
        return ResponseEnvelope(callID: envelope.callID, result: .void)
    }

    var incomingInvocations: AsyncThrowingStream<InvocationEnvelope, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.state.setInvocationContinuation(continuation)
            }
        }
    }

    func sendResponse(_ envelope: ResponseEnvelope) async throws {
        await state.recordSendResponse()
    }

    func close() async throws {
        await state.stop()
    }

    func start() async throws {
        await state.start()
    }

    // MARK: - テストヘルパー

    var startCount: Int {
        get async { await state.startCount }
    }

    var stopCount: Int {
        get async { await state.stopCount }
    }

    var sendInvocationCount: Int {
        get async { await state.sendInvocationCount }
    }

    var sendResponseCount: Int {
        get async { await state.sendResponseCount }
    }

    /// Inject an incoming invocation for testing
    func injectInvocation(_ envelope: InvocationEnvelope) async {
        await state.injectInvocation(envelope)
    }
}

/// スレッドセーフな状態管理
private actor MockTransportState {
    var isActive: Bool = false
    var startCount: Int = 0
    var stopCount: Int = 0
    var sendInvocationCount: Int = 0
    var sendResponseCount: Int = 0
    var invocationContinuation: AsyncThrowingStream<InvocationEnvelope, Error>.Continuation?

    func start() {
        isActive = true
        startCount += 1
    }

    func stop() {
        isActive = false
        stopCount += 1
        invocationContinuation?.finish()
    }

    func recordSendInvocation() {
        sendInvocationCount += 1
    }

    func recordSendResponse() {
        sendResponseCount += 1
    }

    func setInvocationContinuation(_ continuation: AsyncThrowingStream<InvocationEnvelope, Error>.Continuation) {
        invocationContinuation = continuation
    }

    func injectInvocation(_ envelope: InvocationEnvelope) {
        invocationContinuation?.yield(envelope)
    }
}
