import Foundation
import Synchronization

/// Turns a phone request into a call on a `RemoteHost` and the reply message. Shared by `RemoteServer`
/// and the client's in-process demo mode, so both behave the same.
public enum RemoteDispatcher {
    /// The reply to an authenticated request. `hello` is handled by the caller, which checks the token.
    public static func respond(to message: RemoteClientMessage, host: any RemoteHost) async -> RemoteServerMessage {
        do {
            switch message {
            case .hello:
                return .ack
            case .hubSnapshot:
                return .hub(await host.hubSnapshot())
            case .openSession(let sessionID):
                return .transcript(try await host.transcript(sessionID: sessionID))
            case .closeSession:
                return .ack
            case .sendMessage(let m):
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw RemoteError(.badRequest, "The message is empty") }
                let agent = m.agent?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).remoteNilIfEmpty
                try await host.sendMessage(text, to: m.target, agent: agent)
                return .ack
            case .replyPermission(let r):
                try await host.replyPermission(sessionID: r.sessionID, requestID: r.requestID, decision: r.decision)
                return .ack
            case .setPermissionMode(let m):
                try await host.setPermissionMode(m.mode, for: m.target)
                return .ack
            case .interrupt(let target):
                try await host.interrupt(target)
                return .ack
            case .roomControl(let c):
                try await host.controlRoom(c.roomID, action: c.action)
                return .ack
            case .roomsRequest:
                return .rooms(await host.rooms())
            case .usageRequest:
                return .usage(await host.usageSummary())
            }
        } catch let error as RemoteError {
            return .error(error)
        } catch {
            return .error(RemoteError(.failed, error.localizedDescription))
        }
    }
}

extension String {
    var remoteNilIfEmpty: String? { isEmpty ? nil : self }
}

/// Lets exactly one caller through; used to resume a continuation once from callbacks that can race.
final class RemoteResumeOnce: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { value in
            if value { return false }
            value = true
            return true
        }
    }
}
