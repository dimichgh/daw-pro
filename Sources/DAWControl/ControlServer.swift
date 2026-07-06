import Foundation
import Network

/// Loopback-only WebSocket server exposing the control protocol.
/// One JSON ControlRequest per text frame in, one ControlResponse per frame out.
///
/// @unchecked Sendable justification: `listener` and `connections` are only
/// touched on the private serial `queue`; the router is @MainActor and is only
/// called via a MainActor task hop.
public final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dawpro.control-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let router: CommandRouter
    public let port: UInt16

    public init(router: CommandRouter, port: UInt16 = 17600) {
        self.router = router
        self.port = port
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
