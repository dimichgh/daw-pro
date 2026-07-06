import Foundation
import DAWCore

/// The wire shape of an unsolicited transport frame: `{"event":"transport",
/// "transport":{<TransportState JSON>}}`. No `id` — broadcasts are not replies.
struct TransportBroadcast: Encodable, Sendable {
    let event = "transport"
    let transport: TransportState
}

/// Pushes transport state to control clients: immediately on change, ~4 Hz while
/// playing. Deliberately a plain 250 ms poll — no observation machinery. While
/// playing, every tick broadcasts (position keeps moving); when stopped, a tick
/// broadcasts only if the transport differs from what was last sent, so mutations
/// (seek/tempo/loop) surface within a poll interval without spamming idle clients.
@MainActor
public final class TransportBroadcaster {
    private let store: ProjectStore
    private let server: ControlServer
    private var task: Task<Void, Never>?
    private var lastSent: TransportState?

    public init(store: ProjectStore, server: ControlServer) {
        self.store = store
        self.server = server
    }

    public func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { break }
                let transport = self.store.transport
                if transport.isPlaying || transport != self.lastSent {
                    self.push(transport)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func push(_ transport: TransportState) {
        lastSent = transport
        server.broadcast(TransportBroadcast(transport: transport))
    }
}
