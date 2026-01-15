import Foundation
import Distributed
import PeerNode

// MARK: - Message Processing

extension CommunitySystem {
    func processMessages(from transport: any DistributedTransport, peerID: PeerID) async {
        do {
            for try await envelope in transport.messages {
                switch envelope {
                case .invocation(let invocation):
                    // Track sender for response routing
                    state.withLock { s in
                        s.responseRoutes[invocation.callID] = peerID.value
                    }

                    // Handle the invocation
                    let response = await handleInvocation(invocation)

                    // Send response back via the same transport
                    try await transport.send(.response(response))

                case .response(let response):
                    // Handle response to a pending call
                    handleResponse(response)
                }
            }
        } catch {
            // Message stream error
        }

        // Cancel all pending calls - connection is gone
        let pending = pendingCalls.withLock { pending in
            let copy = pending
            pending.removeAll()
            return copy
        }
        for (_, continuation) in pending {
            continuation.resume(throwing: CommunityError.connectionFailed("Peer disconnected: \(peerID.name)"))
        }
    }

    private func handleInvocation(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        // Find the target actor by UUID
        guard let targetActor = registry.find(id: envelope.recipientID) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(RuntimeError.actorNotFound(envelope.recipientID))
            )
        }

        // Create the invocation decoder
        do {
            var decoder = try CodableInvocationDecoder(envelope: envelope)

            // Create a result handler to capture the response
            var capturedResponse: ResponseEnvelope?
            let handler = CodableResultHandler(callID: envelope.callID) { response in
                capturedResponse = response
            }

            // Execute the distributed target
            let target = RemoteCallTarget(envelope.target)
            try await executeDistributedTarget(
                on: targetActor,
                target: target,
                invocationDecoder: &decoder,
                handler: handler
            )

            // Return the response
            if let response = capturedResponse {
                return response
            } else {
                return ResponseEnvelope(
                    callID: envelope.callID,
                    result: .failure(RuntimeError.executionFailed(envelope.target, underlying: "No response captured"))
                )
            }
        } catch {
            let runtimeError: RuntimeError
            if let re = error as? RuntimeError {
                runtimeError = re
            } else {
                runtimeError = RuntimeError.executionFailed(envelope.target, underlying: error.localizedDescription)
            }
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(runtimeError)
            )
        }
    }

    func handleResponse(_ response: ResponseEnvelope) {
        // Find and resume the pending call
        let continuation = pendingCalls.withLock { pending in
            pending.removeValue(forKey: response.callID)
        }
        continuation?.resume(returning: response)
    }
}
