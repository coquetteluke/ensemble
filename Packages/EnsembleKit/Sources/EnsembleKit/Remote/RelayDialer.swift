import CryptoKit
import Foundation
import Synchronization

/// Opens a phone socket on the relay (`/v1/mailbox/<id>/phone`), proves knowledge of the access key derived from the
/// pairing token, and returns the socket once the relay says `paired` (meaning the Mac opened its data socket and every
/// frame after this goes end to end between the phone and the Mac).
public enum RelayDialer {
    /// `wss://` anywhere; plain `ws://` only for loopback (`127.0.0.1` and `localhost`) in Debug builds.
    /// Rejects userinfo, query, fragment, invalid ports, and non-root paths.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        switch scheme {
        case "wss":
            break
        case "ws":
            #if DEBUG
            guard host == "127.0.0.1" || host == "localhost" else { return false }
            #else
            return false
            #endif
        default:
            return false
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        if let port = components.port, !(1...65535).contains(port) {
            return false
        }
        return true
    }

    /// Connects to `relay`, proves the access key for `token`, waits for `paired`, and returns the live WebSocket task
    /// ready for the Ensemble protocol 4 handshake.
    public static func connect(relay: RemotePairing.Relay, token: String, session: URLSession,
                               timeout: Duration) async throws -> URLSessionWebSocketTask {
        guard let baseURL = URL(string: relay.url), isAllowed(baseURL) else {
            throw RemoteError(.badRequest, "The relay address must start with wss://.")
        }
        guard RelayWire.isMailboxID(relay.mailbox) else {
            throw RemoteError(.badRequest, "The relay mailbox in the pairing code is invalid.")
        }
        let endpoint = baseURL.appending(path: "v1/mailbox/\(relay.mailbox)/phone")
        let closeTracker = CloseTracker()
        let task = session.webSocketTask(with: endpoint)
        task.maximumMessageSize = 64 << 20
        task.delegate = closeTracker
        task.resume()

        let timedOut = Mutex(false)
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled {
                timedOut.withLock { $0 = true }
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            do {
                let first = try await receiveControl(from: task)
                let nonce: String
                switch first {
                case .challenge(let n):
                    guard RemoteHandshake.decode(n, expectedCount: 32) != nil else {
                        throw RemoteError(.badRequest, "The relay sent an invalid challenge.")
                    }
                    nonce = n
                default:
                    throw controlError(for: first)
                }

                let accessKey = RelayIdentity.accessKey(token: token)
                let proof = RelayIdentity.phoneProof(accessKey: accessKey, mailboxID: relay.mailbox, nonce: nonce)
                try await task.send(.string(RelayWire.encode(.access(proof: RemoteHandshake.encode(proof)))))

                let second = try await receiveControl(from: task)
                switch second {
                case .waiting: break
                default: throw controlError(for: second)
                }

                let third = try await receiveControl(from: task)
                switch third {
                case .paired: break
                default: throw controlError(for: third)
                }

                try Task.checkCancellation()
                return task
            } catch let error as RemoteError {
                task.cancel(with: .goingAway, reason: nil)
                throw error
            } catch is CancellationError {
                task.cancel(with: .goingAway, reason: nil)
                throw CancellationError()
            } catch {
                let mapped = await closeTracker.mapError(error, task: task, timedOut: timedOut.withLock { $0 })
                task.cancel(with: .goingAway, reason: nil)
                throw mapped
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func receiveControl(from task: URLSessionWebSocketTask) async throws -> RelayControlFrame {
        let message = try await task.receive()
        guard case .string(let text) = message, let frame = RelayWire.decode(text) else {
            throw RemoteError(.badRequest, "Unexpected message from the relay.")
        }
        return frame
    }

    private static func controlError(for frame: RelayControlFrame) -> RemoteError {
        switch frame {
        case .error(let code, let message):
            switch code {
            case .macOffline:
                return RemoteError(.macOffline, "Your Mac is not connected to the relay")
            case .unauthorized:
                let text = message.isEmpty ? "Invalid pairing token. Scan the pairing code on your Mac again." : message
                return RemoteError(.unauthorized, text)
            case .limit:
                return RemoteError(.limit, message.isEmpty ? "Daily relay limit reached." : message)
            case .busy:
                return RemoteError(.busy, message.isEmpty ? "Too many phones are connected to this Mac." : message)
            case .tooBig:
                return RemoteError(.badRequest, message.isEmpty ? "Message too large for the relay." : message)
            case .taken:
                return RemoteError(.failed, message.isEmpty ? "Relay mailbox unavailable." : message)
            }
        case .limit:
            return RemoteError(.limit, "Daily relay limit reached.")
        default:
            return RemoteError(.badRequest, "Unexpected message from the relay.")
        }
    }
}

/// Captures the WebSocket close code and reason when the relay closes without a preceding control frame (for example
/// 4001 on a wrong access proof).
private final class CloseTracker: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct State {
        var info: (code: UInt16, reason: String)?
        var waiter: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let code = UInt16(clamping: closeCode.rawValue)
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let waiter = state.withLock { s -> (@Sendable () -> Void)? in
            s.info = (code, text)
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?()
    }

    func mapError(_ error: any Error, task: URLSessionWebSocketTask, timedOut: Bool) async -> any Error {
        if Task.isCancelled { return CancellationError() }
        if timedOut { return RemoteError(.failed, "The relay did not answer in time.") }
        guard let close = await closeInfo(from: task) else { return error }
        switch close.code {
        case RelayWire.CloseCode.unauthorized:
            return RemoteError(.unauthorized, "Invalid pairing token. Scan the pairing code on your Mac again.")
        case RelayWire.CloseCode.macOffline:
            return RemoteError(.macOffline, "Your Mac is not connected to the relay")
        case RelayWire.CloseCode.noMailbox:
            return RemoteError(.failed, "Your Mac has not registered on the relay yet")
        case RelayWire.CloseCode.limit:
            if close.reason == "busy" {
                return RemoteError(.busy, "Too many phones are connected to this Mac.")
            }
            return RemoteError(.limit, "Daily relay limit reached.")
        case RelayWire.CloseCode.timeout:
            return RemoteError(.failed, "Your Mac did not answer through the relay in time.")
        case RelayWire.CloseCode.tooBig:
            return RemoteError(.badRequest, "Message too large for the relay.")
        case RelayWire.CloseCode.protocolError:
            return RemoteError(.badRequest, "The relay did not accept a message from this iPhone.")
        default:
            return error
        }
    }

    private func closeInfo(from task: URLSessionWebSocketTask) async -> (code: UInt16, reason: String)? {
        if let immediate = immediateInfo(from: task) { return immediate }
        let once = RemoteResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.info != nil { return true }
                s.waiter = {
                    if once.claim() { continuation.resume() }
                }
                return false
            }
            if resumeNow {
                if once.claim() { continuation.resume() }
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                self.state.withLock { $0.waiter = nil }
                if once.claim() { continuation.resume() }
            }
        }
        return immediateInfo(from: task)
    }

    private func immediateInfo(from task: URLSessionWebSocketTask) -> (code: UInt16, reason: String)? {
        if let recorded = state.withLock({ $0.info }) { return recorded }
        let raw = task.closeCode.rawValue
        guard raw > 0, let code = UInt16(exactly: raw) else { return nil }
        let text = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (code, text)
    }
}
