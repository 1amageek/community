import Foundation
import PeerNode

// MARK: - Name Registry

extension CommunitySystem {
    /// Register a name alias for an actor
    public func registerName(_ name: String, for actorID: ActorID) throws {
        try nameRegistry.register(name: name, actorID: actorID)
    }

    /// Unregister a name alias
    public func unregisterName(_ name: String) {
        nameRegistry.unregister(name: name)
    }

    /// Find actor ID by name (local only)
    public func findLocalActorID(byName name: String) -> ActorID? {
        nameRegistry.find(name: name)
    }

    /// Get all registered names (local only)
    public func allLocalNames() -> [String] {
        nameRegistry.allNames()
    }
}

// MARK: - Member Management

extension CommunitySystem {
    /// Get all local members (basic info only)
    public func localMembers() -> [MemberInfo] {
        nameRegistry.allEntries().map { (name, actorID) in
            MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
    }

    /// Get all members (local + remote) - basic info only
    public func allMembers() -> [MemberInfo] {
        let local = localMembers()
        let remote = state.withLock { Array($0.remoteMembers.values) }
        var members = local
        members.append(contentsOf: remote)
        return members
    }

    /// Get local members with process status (no remote fetching)
    public func localMembersWithStatus() async -> [MemberInfo] {
        var members: [MemberInfo] = []

        for (name, actorID) in nameRegistry.allEntries() {
            if let member = registry.find(id: actorID.id) as? Member {
                let command = try? await member.getCommand()
                let cwd = try? await member.getCwd()
                let foregroundProcess = try? await member.getForegroundProcess()

                members.append(MemberInfo(
                    name: name,
                    actorID: actorID,
                    peerID: localPeerInfo.peerID,
                    transport: "local",
                    command: command,
                    cwd: cwd,
                    foregroundProcess: foregroundProcess
                ))
            } else {
                members.append(MemberInfo(
                    name: name,
                    actorID: actorID,
                    peerID: localPeerInfo.peerID,
                    transport: "local"
                ))
            }
        }

        return members
    }

    /// Get cached remote members (no re-fetching)
    public func remoteMembersCached() -> [MemberInfo] {
        state.withLock { Array($0.remoteMembers.values) }
    }

    /// Get all members with process status (local members include PTY info)
    public func allMembersWithStatus() async -> [MemberInfo] {
        var members: [MemberInfo] = []

        // Local members - fetch process info from Member actors
        for (name, actorID) in nameRegistry.allEntries() {
            if let member = registry.find(id: actorID.id) as? Member {
                let command = try? await member.getCommand()
                let cwd = try? await member.getCwd()
                let foregroundProcess = try? await member.getForegroundProcess()

                members.append(MemberInfo(
                    name: name,
                    actorID: actorID,
                    peerID: localPeerInfo.peerID,
                    transport: "local",
                    command: command,
                    cwd: cwd,
                    foregroundProcess: foregroundProcess
                ))
            } else {
                members.append(MemberInfo(
                    name: name,
                    actorID: actorID,
                    peerID: localPeerInfo.peerID,
                    transport: "local"
                ))
            }
        }

        // Remote members - fetch process info from their peers
        let remoteMembersList = state.withLock { Array($0.remoteMembers.values) }

        // Group by peerID to batch requests
        var membersByPeer: [PeerID: [MemberInfo]] = [:]
        for member in remoteMembersList {
            membersByPeer[member.peerID, default: []].append(member)
        }

        // Fetch process info from each peer with timeout
        for (peerID, peerMembers) in membersByPeer {
            let fetchedMembers = await fetchRemoteMembersWithTimeout(peerID: peerID, peerMembers: peerMembers)
            members.append(contentsOf: fetchedMembers)
        }

        return members
    }

    /// Fetch remote members with a timeout, returning cached info on failure
    private func fetchRemoteMembersWithTimeout(peerID: PeerID, peerMembers: [MemberInfo]) async -> [MemberInfo] {
        // Use Task with timeout instead of task group to avoid cancellation issues
        let fetchTask = Task<[MemberInfo], Error> {
            // Connect to peer if not already connected
            if self.node.transport(for: peerID) == nil {
                try await self.node.connect(to: peerID)

                // Start message processing for this connection
                if let transport = self.node.transport(for: peerID) {
                    let task: Task<Void, Never> = Task { [weak self] in
                        guard let self else { return }
                        await self.processMessages(from: transport, peerID: peerID)
                    }
                    self.state.withLock { s in
                        s.messageTasks.append(task)
                    }
                }
            }

            let remoteSystemActor = try self.remoteSystemActor(peerID: peerID)
            let remoteInfos = try await remoteSystemActor.listMembers()

            // Match and update with fresh info
            var result: [MemberInfo] = []
            for member in peerMembers {
                if let freshInfo = remoteInfos.first(where: { $0.name == member.name }) {
                    result.append(freshInfo)
                } else {
                    result.append(member)
                }
            }
            return result
        }

        // Wait with timeout
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(3))
            fetchTask.cancel()
        }

        do {
            let result = try await fetchTask.value
            timeoutTask.cancel()
            return result
        } catch {
            timeoutTask.cancel()
            // Failed or timeout - use cached info
            return peerMembers
        }
    }

    /// Find a member by name (searches local + remote)
    /// - Parameter name: The member name to search for
    /// - Returns: MemberInfo if found, nil otherwise
    public func findMember(byName name: String) -> MemberInfo? {
        // First check local
        if let actorID = nameRegistry.find(name: name) {
            return MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
        // Then check remote
        return state.withLock { s in
            s.remoteMembers.values.first { $0.name == name }
        }
    }
}
