import Foundation
import SocketIO
import os

/// Socket.IO channel for one account's site namespace. Authentication rides
/// the handshake headers (Bearer token + Frappe site name); message rooms are
/// `doc_subscribe` rooms on Raven Channel docs, rejoined wholesale whenever
/// the namespace reconnects. Server events arrive as (name, payload) pairs.
@MainActor
public final class RavenRealtime {
    private static let log = Logger(subsystem: "ch.goodvantage.Nevermore", category: "Realtime")
    public let account: Account
    private let accessToken: String
    private let onEvent: @MainActor (String, JSONValue) -> Void
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    /// Channels the caller wants warm. The server drops every room on
    /// disconnect, so this desired set is the only durable state.
    private var desired = Set<String>()
    /// Rooms emitted on the live socket generation; diffed against `desired`.
    private var joined = Set<String>()

    public init(account: Account, accessToken: String, onEvent: @escaping @MainActor (String, JSONValue) -> Void) {
        self.account = account
        self.accessToken = accessToken
        self.onEvent = onEvent
    }

    public func connect() {
        if let socket {
            socket.connect()
            return
        }
        let headers = [
            "Origin": account.origin.absoluteString,
            "Authorization": "Bearer \(accessToken)",
            // What nginx sets in production: the site behind a host that may
            // not equal the sitename.
            "X-Frappe-Site-Name": account.siteName,
        ]
        let manager = SocketManager(socketURL: account.origin, config: [
            .log(false),
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectAttempts(-1),
            .reconnectWait(1),
            .reconnectWaitMax(5),
            .extraHeaders(headers),
            .handleQueue(.main),
        ])
        let socket = manager.socket(forNamespace: "/" + account.siteName)
        socket.on(clientEvent: .connect) { [weak self] _, _ in Task { @MainActor in self?.didConnect() } }
        socket.on(clientEvent: .disconnect) { [weak self] data, _ in Task { @MainActor in self?.didDisconnect(data) } }
        socket.on(clientEvent: .error) { [weak self] data, _ in Task { @MainActor in self?.emit("error", Self.payload(data)) } }
        socket.onAny { [weak self] event in Task { @MainActor in self?.didReceive(event) } }
        self.manager = manager
        self.socket = socket
        socket.connect()
    }

    public func disconnect() {
        socket?.removeAllHandlers()
        manager?.disconnect()
        socket = nil
        manager = nil
        joined.removeAll()
    }

    /// Diff desired rooms against the live socket's joined set. Calls while
    /// disconnected only update the desired set; the next namespace connect
    /// re-subscribes everything.
    public func setChannels(_ channels: Set<String>) {
        desired = channels
        guard let socket, socket.status == .connected else { return }
        let added = channels.subtracting(joined)
        for id in added { socket.emit("doc_subscribe", RavenEndpoints.roomDoctype, id) }
        let removed = joined.subtracting(channels)
        for id in removed { socket.emit("doc_unsubscribe", RavenEndpoints.roomDoctype, id) }
        if !added.isEmpty || !removed.isEmpty { Self.log.info("Requested room changes: \(added.count) added, \(removed.count) removed") }
        joined.formUnion(added)
        joined.subtract(removed)
    }

    private func didConnect() {
        // A fresh connection owns no rooms: rejoin the full desired set rather
        // than trusting diffs from a previous socket generation.
        joined.removeAll()
        guard let socket else { return }
        for id in desired {
            socket.emit("doc_subscribe", RavenEndpoints.roomDoctype, id)
            joined.insert(id)
        }
        for doctype in RavenEndpoints.doctypeSubscriptions {
            socket.emit("doctype_subscribe", doctype)
        }
        Self.log.info("Socket connected; requested subscriptions for \(self.desired.count) channel rooms")
        onEvent("connect", .null)
    }

    private func didDisconnect(_ data: [Any]) {
        Self.log.info("Socket disconnected")
        joined.removeAll()
        onEvent("disconnect", Self.payload(data))
    }

    private func didReceive(_ event: SocketAnyEvent) {
        // onAny also surfaces the client's own lifecycle events; forward only
        // server-emitted names.
        if SocketClientEvent(rawValue: event.event) != nil { return }
        if event.event == "message_created" { Self.log.debug("Received message_created event") }
        emit(event.event, Self.payload(event.items ?? []))
    }

    private func emit(_ name: String, _ payload: JSONValue) {
        onEvent(name, payload)
    }

    /// First socket argument as JSONValue; `.null` when absent or opaque.
    static func payload(_ items: [Any]) -> JSONValue {
        guard let first = items.first else { return .null }
        return JSONValue(socketValue: first)
    }
}

extension JSONValue {
    /// Converts Foundation objects arriving over Socket.IO into JSONValue.
    /// Booleans are distinguished from numbers via CFBoolean; opaque values
    /// degrade to a descriptive string rather than crashing the event stream.
    init(socketValue value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let text as String:
            self = .string(text)
        case let array as [Any]:
            self = .array(array.map { JSONValue(socketValue: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(socketValue: $0) })
        default:
            self = .string(String(describing: value))
        }
    }
}
