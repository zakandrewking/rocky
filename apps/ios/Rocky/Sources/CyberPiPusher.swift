import Foundation
import Network

/// Swift port of apps/robot/scripts/push.mjs's wire behavior -- same protocol, same
/// bootstrap.py on the other end, just a different sender. Connects to the CyberPi's OTA
/// listener, writes the payload's bytes, half-closes so bootstrap.py's recv loop sees EOF, and
/// returns whatever single-line reply it sends back (e.g. "ok, wrote 1234 bytes").
enum CyberPiPusher {
    static func push(fileAt url: URL, to host: String, port: UInt16 = 8766, timeout: TimeInterval = 5) async throws -> String {
        let code = try Data(contentsOf: url)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RockyError.invalidAddress("port \(port) is out of range")
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var settled = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    continuation.resume()
                case .failed(let error):
                    guard !settled else { return }
                    settled = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // .contentProcessed fires once the bytes are handed off, then isComplete: true closes
            // our write side -- bootstrap.py's recv loop is reading until EOF, so this half-close
            // is what tells it "that's the whole payload," same as push.mjs's socket.end(code).
            connection.send(content: code, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var reply = Data()
            nonisolated(unsafe) var settled = false
            let timeoutWorkItem = DispatchWorkItem {
                guard !settled else { return }
                settled = true
                continuation.resume(throwing: RockyError.timedOut("waiting for the board's reply"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 0, maximumLength: 4096) { data, _, isComplete, error in
                    if let data {
                        reply.append(data)
                    }
                    if isComplete || error != nil {
                        guard !settled else { return }
                        settled = true
                        timeoutWorkItem.cancel()
                        if let error, reply.isEmpty {
                            continuation.resume(throwing: error)
                        } else {
                            let text = String(decoding: reply, as: UTF8.self)
                            continuation.resume(returning: text.isEmpty ? "(board closed without replying)" : text)
                        }
                        return
                    }
                    receiveNext()
                }
            }
            receiveNext()
        }
    }
}
