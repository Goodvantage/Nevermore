import AppKit
import RavenProtocol

@MainActor enum CollectionBatchActions {
    static let maximumSelection = 100

    struct Transport {
        let markRead: @MainActor ([String]) async throws -> Void
        let unreadIDs: @MainActor () async throws -> Set<String>
    }

    // Notification row names can identify a mention rather than its message.
    // Only the contract's message_id is safe for this endpoint.
    static func messageIDs(_ rows: [JSONValue]) -> [String]? {
        guard !rows.isEmpty, rows.count <= maximumSelection else { return nil }
        var seen = Set<String>()
        var ids: [String] = []
        for row in rows {
            guard let id = row["message_id"].string, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  id.utf8.count <= 1024,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    static func transport(session: AccountSession) -> Transport {
        Transport(markRead: { ids in
            _ = try await session.mutate("raven.api.notifications.mark_message_notifications_read", ["message_ids": .array(ids.map(JSONValue.string))])
        }, unreadIDs: {
            let value = try await session.client.rpc("raven.api.notifications.get_unread_notification_message_ids")
            guard case .array(let values) = value,
                  values.allSatisfy({ $0.string != nil }) else { throw RavenError.invalidResponse }
            return Set(values.compactMap(\.string))
        })
    }
}

extension CollectionWindow: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(markSelectedRead) { return canMarkSelectedRead }
        return active
    }
}

extension CollectionWindow {
    var selectedBatchRows: [JSONValue] {
        table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0] : nil }
    }

    var canMarkSelectedRead: Bool {
        guard kind == .inbox, active, !isLoading, !isBatchRunning,
              let session, !session.readOnly,
              !session.demo || batchTransport != nil else { return false }
        return CollectionBatchActions.messageIDs(selectedBatchRows) != nil
    }

    @objc func markSelectedRead() {
        guard canMarkSelectedRead, let session,
              let ids = CollectionBatchActions.messageIDs(selectedBatchRows) else { return }
        // Capture the immutable snapshot before suspension. Selection changes
        // cannot redirect the mutation to another row or another account.
        let transport = batchTransport ?? CollectionBatchActions.transport(session: session)
        let generation = UUID(); batchGeneration = generation
        isBatchRunning = true; statusMessage = ""; updateChrome()
        batchTask = Task { [weak self] in
            guard let self, self.active, self.batchGeneration == generation, !Task.isCancelled else { return }
            var acknowledged = false
            do {
                try await transport.markRead(ids)
                acknowledged = true
            } catch {
                // Do not replay a mutation with an uncertain outcome. A
                // canonical read below can heal attention state independently.
            }
            guard self.active, self.batchGeneration == generation, !Task.isCancelled else { return }
            var reconciled = false
            do {
                let unread = try await transport.unreadIDs()
                guard self.active, self.batchGeneration == generation, !Task.isCancelled else { return }
                session.unreadNotificationIDs = unread
                self.pager.records = self.pager.records.map { row in
                    guard let id = row["message_id"].string else { return row }
                    var fields = row.object; fields["is_read"] = .bool(!unread.contains(id))
                    return .object(fields)
                }
                self.applyFilter(); self.table.reloadData(); session.notify()
                reconciled = true
            } catch { /* Keep the last known attention set on read failure. */ }
            guard self.active, self.batchGeneration == generation, !Task.isCancelled else { return }
            self.isBatchRunning = false; self.batchTask = nil
            if !acknowledged {
                self.statusMessage = "Could not confirm that the selected notifications were marked read. Refresh before trying again."
            } else if !reconciled {
                self.statusMessage = "Notifications were marked read, but unread status could not be refreshed. Refresh this account to check."
            } else { self.statusMessage = "" }
            self.updateChrome()
        }
    }
}
