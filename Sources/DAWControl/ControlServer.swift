import Foundation
import Network

/// Loopback-only WebSocket server exposing the control protocol.
/// One JSON ControlRequest per text frame in, one ControlResponse per frame out.
///
/// @unchecked Sendable justification: `listener` and `connections` are only
/// touched on the private serial `queue`; the router is @MainActor and is only
/// called via a MainActor task hop; `livenessSnapshot` is an immutable
/// `@Sendable` closure fixed at init.
public final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dawpro.control-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let router: CommandRouter
    public let port: UInt16

    /// m18-b: main-actor liveness read for the QUEUE tier. Routing hops to the
    /// MainActor (`dispatch`), so during a main-actor wedge the socket keeps
    /// reading frames while every command silently hangs — the one failure the
    /// normal path can never report. When this provider says "wedged",
    /// `dispatch` answers ON THE QUEUE, before the hop (see `wedgeIntercept`).
    /// nil (headless tests, older callers) = no interception, byte-identical
    /// pre-m18-b behavior.
    private let livenessSnapshot: (@Sendable () -> MainActorLivenessSnapshot?)?

    public init(router: CommandRouter, port: UInt16 = 17600,
                livenessSnapshot: (@Sendable () -> MainActorLivenessSnapshot?)? = nil) {
        self.router = router
        self.port = port
        self.livenessSnapshot = livenessSnapshot
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async { self.accept(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    // MARK: - Connections (all on `queue`)

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async { self.drop(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.dispatch(data, on: connection)
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                self.queue.async { self.drop(connection) }
            }
        }
    }

    private func dispatch(_ data: Data, on connection: NWConnection) {
        // m18-b wedge honesty: consult the liveness snapshot HERE, on the
        // server queue, before the MainActor hop below. A wedged main actor
        // would swallow the Task forever; the queue tier answers instead so an
        // agent never faces a silent hang. Runs on `queue` (receiveMessage
        // callback), so `send` below is queue-legal.
        if let snapshot = livenessSnapshot?(),
           let response = Self.wedgeIntercept(data, snapshot: snapshot) {
            send(response, on: connection)
            return
        }
        Task { @MainActor [router] in
            let response: ControlResponse
            do {
                let request = try JSONDecoder().decode(ControlRequest.self, from: data)
                response = await router.handle(request)
            } catch {
                response = .failure("?", "malformed request JSON: \(error.localizedDescription)")
            }
            self.send(response, on: connection)
        }
    }

    // MARK: - Main-actor wedge interception (m18-b, queue tier)

    /// Decides the queue-tier answer for one inbound frame while the main
    /// actor may be wedged. Returns nil when responsive (take the normal
    /// MainActor route). Static + internal so the decision is testable with a
    /// fake snapshot — no sockets, no wall time.
    ///
    /// The wedged rules (ZERO new wire commands — the surface rides existing
    /// verbs):
    /// · `engine.watchdogStatus` answers from the snapshot with the additive
    ///   `mainActor` field ONLY: the engine watchdog fields are PRODUCED on
    ///   the main actor (`store.watchdogStatus()`), unreadable during a wedge
    ///   — rather than dress a stale cache as live data they are honestly
    ///   OMITTED; `mainActor: {responsive: false, wedgedForSeconds}` carries
    ///   the whole story. (The healthy path adds `mainActor: {responsive:
    ///   true}` next to the full engine fields — see Commands.swift.)
    /// · Every other command fails fast with the teaching error (wire errors
    ///   are strings) instead of hanging until recovery.
    /// · Malformed JSON gets the usual malformed error, still answered here.
    static func wedgeIntercept(_ data: Data,
                               snapshot: MainActorLivenessSnapshot) -> ControlResponse? {
        guard !snapshot.responsive, let wedgedFor = snapshot.wedgedForSeconds else { return nil }
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
            return .failure("?", "malformed request JSON (answered off-main during a main-actor wedge)")
        }
        if request.command == "engine.watchdogStatus" {
            return .success(request.id, .object([
                "mainActor": .object([
                    "responsive": .bool(false),
                    "wedgedForSeconds": .number(wedgedFor),
                ])
            ]))
        }
        return .failure(request.id, wedgeTeachingError(wedgedForSeconds: wedgedFor))
    }

    /// The teaching error every non-watchdog command receives during a wedge:
    /// what happened, for how long, where liveness IS readable, and when
    /// normal service resumes. An agent must never guess at a silent hang.
    static func wedgeTeachingError(wedgedForSeconds: Double) -> String {
        "main actor has been unresponsive for "
            + String(format: "%.1f", wedgedForSeconds)
            + " s — the app UI is wedged; engine.watchdogStatus reports liveness; "
            + "other commands cannot run until it recovers."
    }

    private func send(_ response: ControlResponse, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(response) else { return }
        sendFrame(payload, on: connection)
    }

    /// Sends one pre-encoded text frame. Must run on `queue`.
    private func sendFrame(_ payload: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: payload,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    // MARK: - Broadcast (unsolicited server → client frames)

    /// Encodes `payload` once and pushes it as a text frame to every live
    /// connection. Used for transport/position events, which carry no request
    /// `id`. Connection access stays on the private serial `queue`, keeping the
    /// @unchecked Sendable justification intact.
    public func broadcast(_ payload: some Encodable & Sendable) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        queue.async {
            for connection in self.connections.values {
                self.sendFrame(data, on: connection)
            }
        }
    }
}
