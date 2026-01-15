import Foundation
import Distributed

// MARK: - Remote Call (Client Side)

extension CommunitySystem {
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        // Check if local
        if actor.id.peerID == localPeerInfo.peerID {
            return try await executeLocally(
                on: actor,
                target: target,
                invocation: &invocation,
                returning: returning
            )
        }

        // Remote call via routes
        return try await executeRemotely(
            on: actor,
            target: target,
            invocation: &invocation,
            returning: returning
        )
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        // Check if local
        if actor.id.peerID == localPeerInfo.peerID {
            try await executeLocallyVoid(
                on: actor,
                target: target,
                invocation: &invocation
            )
            return
        }

        // Remote call via routes
        try await executeRemotelyVoid(
            on: actor,
            target: target,
            invocation: &invocation
        )
    }
}

// MARK: - Local Execution

extension CommunitySystem {
    func executeLocally<Act, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Res: Codable {
        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        var decoder = try CodableInvocationDecoder(envelope: envelope)

        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        guard let response = capturedResponse else {
            throw CommunityError.invalidResponse
        }

        switch response.result {
        case .success(let data):
            return try JSONDecoder().decode(Res.self, from: data)
        case .void:
            fatalError("Expected return value but got void")
        case .failure(let error):
            throw error
        }
    }

    func executeLocallyVoid<Act>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID {
        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        guard let targetActor = registry.find(id: envelope.recipientID) else {
            throw RuntimeError.actorNotFound(envelope.recipientID)
        }

        var decoder = try CodableInvocationDecoder(envelope: envelope)

        var capturedResponse: ResponseEnvelope?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            capturedResponse = response
        }

        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        guard let response = capturedResponse else {
            throw CommunityError.invalidResponse
        }

        if case .failure(let error) = response.result {
            throw error
        }
    }
}

// MARK: - Remote Execution

extension CommunitySystem {
    func executeRemotely<Act, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        returning: Res.Type
    ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID, Res: Codable {
        // Find transport for target peer
        guard let transport = node.transport(for: actor.id.peerID) else {
            throw CommunityError.peerNotFound(actor.id.peerID.value)
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Send invocation and wait for response
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseEnvelope, Error>) in
            // Register pending call
            pendingCalls.withLock { pending in
                pending[envelope.callID] = continuation
            }

            // Send the invocation
            Task {
                do {
                    try await transport.send(.invocation(envelope))
                } catch {
                    // If sending fails, remove pending and resume with error
                    let cont = self.pendingCalls.withLock { pending in
                        pending.removeValue(forKey: envelope.callID)
                    }
                    cont?.resume(throwing: error)
                }
            }
        }

        switch response.result {
        case .success(let resultData):
            return try JSONDecoder().decode(Res.self, from: resultData)
        case .void:
            fatalError("Expected return value but got void")
        case .failure(let error):
            throw error
        }
    }

    func executeRemotelyVoid<Act>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder
    ) async throws
    where Act: DistributedActor, Act.ID == ActorID {
        // Find transport for target peer
        guard let transport = node.transport(for: actor.id.peerID) else {
            throw CommunityError.peerNotFound(actor.id.peerID.value)
        }

        invocation.recordTarget(target)

        let envelope = try invocation.makeInvocationEnvelope(
            recipientID: actor.id.id,
            senderID: localPeerInfo.peerID.value
        )

        // Send invocation and wait for response
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseEnvelope, Error>) in
            // Register pending call
            pendingCalls.withLock { pending in
                pending[envelope.callID] = continuation
            }

            // Send the invocation
            Task {
                do {
                    try await transport.send(.invocation(envelope))
                } catch {
                    // If sending fails, remove pending and resume with error
                    let cont = self.pendingCalls.withLock { pending in
                        pending.removeValue(forKey: envelope.callID)
                    }
                    cont?.resume(throwing: error)
                }
            }
        }

        if case .failure(let error) = response.result {
            throw error
        }
    }
}
