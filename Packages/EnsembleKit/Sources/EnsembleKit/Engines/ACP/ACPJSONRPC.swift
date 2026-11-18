import Foundation

// JSON-RPC 2.0 over newline-delimited stdio, as the Agent Client Protocol uses it: one JSON object per line, UTF-8,
// no embedded newlines. Both sides send requests, so ids from the agent can be numbers (OpenCode starts at 0) or
// strings (Antigravity sends "1", "2", ...), and the answer must echo the id exactly.

/// A JSON-RPC id: a number or a string.
enum ACPRequestID: Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    init?(_ value: JSONValue?) {
        switch value {
        case .number(let number)? where number.rounded() == number && abs(number) < 9_007_199_254_740_992:
            self = .number(Int(number))
        case .string(let text)?:
            self = .string(text)
        default:
            return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .number(let number): .number(Double(number))
        case .string(let text): .string(text)
        }
    }

    var description: String {
        switch self {
        case .number(let number): String(number)
        case .string(let text): text
        }
    }
}

/// A JSON-RPC error object.
struct ACPRPCError: Error, Equatable, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// ACP: the agent needs the user to sign in first.
    static let authRequired = -32000
    /// ACP: the session or resource does not exist.
    static let resourceNotFound = -32002
}

/// One line on the wire, decoded.
enum ACPMessage: Equatable, Sendable {
    case request(id: ACPRequestID, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: ACPRequestID, result: JSONValue)
    case failure(id: ACPRequestID?, error: ACPRPCError)

    /// Decodes one line. Returns nil for blank lines and anything that is not a JSON-RPC 2.0 object (agents sometimes
    /// print log text to stdout; it is skipped).
    static func decode(line: String) -> ACPMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = JSONValue.acpParse(line: trimmed) else { return nil }
        return decode(json)
    }

    static func decode(_ json: JSONValue) -> ACPMessage? {
        guard case .object(let object) = json else { return nil }
        let id = ACPRequestID(object["id"])
        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .null
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        if let error = object["error"], case .object = error {
            let rpc = ACPRPCError(code: error["code"]?.acpInt ?? ACPRPCError.internalError,
                                  message: error["message"]?.stringValue ?? "Unknown error", data: error["data"])
            return .failure(id: id, error: rpc)
        }
        if let id, object.keys.contains("result") {
            return .response(id: id, result: object["result"] ?? .null)
        }
        return nil
    }

    /// The message as one line of JSON (with the trailing newline).
    var lineData: Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            if params != .null { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if params != .null { object["params"] = params }
        case .response(let id, let result):
            object["id"] = id.json
            object["result"] = result
        case .failure(let id, let error):
            object["id"] = id?.json ?? .null
            var body: [String: JSONValue] = ["code": .number(Double(error.code)), "message": .string(error.message)]
            if let data = error.data { body["data"] = data }
            object["error"] = .object(body)
        }
        return JSONValue.object(object).acpLineData
    }
}

/// Splits a byte stream into lines (newline separated, UTF-8). A partial line waits for the rest; `\r\n` is accepted.
/// Lines longer than `maxLineBytes` are dropped (a runaway agent must not grow memory without bound).
final class ACPLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var discarding = false
    let maxLineBytes: Int

    init(maxLineBytes: Int = 64 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if discarding {
                    discarding = false
                    continue
                }
                if line.last == 0x0D { line = line.dropLast() }
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            if pending.count > maxLineBytes {
                pending.removeAll()
                discarding = true
            }
            return lines
        }
    }

    func finish() -> [String] {
        lock.withLock {
            defer { pending.removeAll() }
            guard !discarding, !pending.isEmpty else { return [] }
            var line = pending
            if line.last == 0x0D { line = line.dropLast() }
            return line.isEmpty ? [] : [String(decoding: line, as: UTF8.self)]
        }
    }
}

// MARK: JSON helpers (own names so they never clash with other engines' helpers)

extension JSONValue {
    var acpInt: Int? {
        if case .number(let value) = self, value.isFinite, abs(value) < 9_007_199_254_740_992 { return Int(value) }
        return nil
    }

    var acpBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    static func acpParse(line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON with a trailing newline, never containing a raw newline (JSON escapes them inside strings).
    var acpLineData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }

    /// A non-empty string value.
    var acpText: String? {
        guard let text = stringValue, !text.isEmpty else { return nil }
        return text
    }
}
