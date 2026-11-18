import Foundation
@testable import EnsembleKit

/// Real OpenCode 2.3.0 responses captured from the local service with the mock model
/// (paths replaced with /tmp/ensemble-probe and /Users/me). See Fixtures/README.md.
enum Fixtures {
    static func url(_ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        return Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
