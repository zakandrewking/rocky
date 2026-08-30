import Foundation

/// An ordered WebSocket writer that does not mistake `resume()` for "connected".
///
/// `URLSessionWebSocketTask.send` can fail with "Socket is not connected" for a few hundred
/// milliseconds after `resume()`. Both voice providers used to write immediately, so a perfectly
/// healthy socket lost its first (and most important) frame. This transport holds one FIFO and
/// retries its head until the handshake is genuinely ready. Only after the first successful write
/// does it begin receiving.
@MainActor
final class SpeechWebSocket {
    var onMessage: ((URLSessionWebSocketTask.Message) -> Void)?
    var onError: ((String) -> Void)?
    var onDebug: ((String) -> Void)?

    private struct Pending {
        let json: String
        let queuedAt: Date
    }

    private static let openTimeout: Duration = .seconds(5)
    private static let retryDelay: Duration = .milliseconds(80)

    private let task: URLSessionWebSocketTask
    private var pending: [Pending] = []
    private var sending = false
    private var receiving = false
    private var cancelled = false
    private var retryTask: Task<Void, Never>?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
    }

    func start() {
        task.resume()
    }

    func send(json: String) {
        guard !cancelled else { return }
        pending.append(Pending(json: json, queuedAt: Date()))
        drain()
    }

    func cancel() {
        cancelled = true
        retryTask?.cancel()
        retryTask = nil
        pending.removeAll()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func drain() {
        guard !cancelled, !sending, let next = pending.first else { return }
        sending = true
        task.send(.string(next.json)) { [weak self] error in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                self.sending = false
                if let error {
                    let waited = Date().timeIntervalSince(next.queuedAt)
                    if waited < Self.seconds(Self.openTimeout) {
                        self.retryTask?.cancel()
                        self.retryTask = Task { [weak self] in
                            try? await Task.sleep(for: Self.retryDelay)
                            guard !Task.isCancelled else { return }
                            self?.drain()
                        }
                        return
                    }
                    self.fail("socket did not become writable in 5s: \(error.localizedDescription)")
                    return
                }

                self.pending.removeFirst()
                if !self.receiving {
                    self.receiving = true
                    self.onDebug?("socket ready after \(Int(Date().timeIntervalSince(next.queuedAt) * 1000))ms; flushing \(self.pending.count) queued frame(s)")
                    self.receive()
                }
                self.drain()
            }
        }
    }

    private func receive() {
        guard !cancelled else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                switch result {
                case .failure(let error):
                    self.fail("socket receive failed: \(error.localizedDescription)")
                case .success(let message):
                    self.onMessage?(message)
                    self.receive()
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard !cancelled else { return }
        cancelled = true
        retryTask?.cancel()
        retryTask = nil
        pending.removeAll()
        task.cancel(with: .goingAway, reason: nil)
        onError?(message)
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
