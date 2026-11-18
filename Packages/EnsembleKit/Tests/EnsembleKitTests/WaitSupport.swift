import Foundation
import Observation
import Synchronization
import Testing

/// How long tests wait for things that should happen.
///
/// Tests wait on the thing itself (an event, a state change) and give up only at a ceiling no passing test comes
/// near. The ceiling is long because a Mac running several builds and test runs at once can be many times slower than
/// an idle one, and a short limit turns that into a failure that says nothing about the code. A fixed sleep is left
/// only where a test checks that something does not happen and nothing announces that.
enum TestWait {
    /// The longest a test waits for one thing.
    static let ceiling: Duration = .seconds(ceilingSeconds)
    /// The same in seconds, for helpers that take a `Double`.
    static let ceilingSeconds: Double = 180
    /// How often a condition is checked again when nothing it observes has changed. Conditions that read only
    /// `@Observable` state are checked as soon as it changes; this catches everything else (a fake's lock-protected
    /// state, a file, a socket).
    static let poll: Duration = .milliseconds(20)
    /// A `PreviewEngine` delay scale for tests that act while a turn is still running. A turn takes minutes at this
    /// scale, so it is still running however slow the machine is; tests that use it never wait for such a turn to end
    /// on its own.
    static let longTurnScale: Double = 30
}

/// A wait that reached its ceiling.
struct WaitTimeout: Error, CustomStringConvertible {
    var description: String
}

/// Waits until `condition` holds, or throws `WaitTimeout` after `timeout`.
///
/// The condition runs on the caller's actor. It is checked again whenever an `@Observable` value it read changes, and
/// every `poll` otherwise. The failure message names `what` and the line that waited; `details` is added to it (for
/// example the state the test was looking at).
func waitUntil(_ what: String = "the condition", timeout: Duration = TestWait.ceiling, poll: Duration = TestWait.poll,
               isolation: isolated (any Actor)? = #isolation,
               sourceLocation: SourceLocation = #_sourceLocation,
               details: () -> String = { "" },
               _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let wake = Wake()
    while true {
        // Observe again only once the last observation has fired; until then it still covers what the condition read.
        let met = wake.beginObserving()
            ? withObservationTracking(condition, onChange: { wake.fire(observed: true) })
            : condition()
        if met { return }
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw WaitTimeout(what: what, timeout: timeout, at: sourceLocation, details: details())
        }
        let next = min(clock.now.advanced(by: poll), deadline)
        let timer = Task.detached {
            try? await Task.sleep(until: next, clock: .continuous)
            if !Task.isCancelled { wake.fire(observed: false) }
        }
        await withCheckedContinuation { wake.wait($0) }
        timer.cancel()
    }
}

/// Waits until `condition` holds, checking it every `poll`, or throws `WaitTimeout` after `timeout`. For conditions
/// that have to await (an actor's state, an engine call); use `waitUntil` for everything else.
func pollUntil(_ what: String = "the condition", timeout: Duration = TestWait.ceiling, poll: Duration = TestWait.poll,
               isolation: isolated (any Actor)? = #isolation,
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try await !condition() {
        guard clock.now < deadline else {
            throw WaitTimeout(what: what, timeout: timeout, at: sourceLocation, details: "")
        }
        try await Task.sleep(until: min(clock.now.advanced(by: poll), deadline), clock: .continuous)
    }
}

extension WaitTimeout {
    init(what: String, timeout: Duration, at location: SourceLocation, details: String) {
        var text = "Timed out after \(timeout) waiting for \(what) (\(location.fileName):\(location.line))."
        if !details.isEmpty { text += "\n" + details }
        self.init(description: text)
    }
}

/// Wakes a waiting check when an observed value changes or the poll timer fires, whichever comes first. Either may
/// fire before the check starts waiting; the wait then returns at once.
private final class Wake: Sendable {
    private struct State {
        var fired = false
        var observing = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// True when no observation is registered, and marks one as registered.
    func beginObserving() -> Bool {
        state.withLock { s in
            defer { s.observing = true }
            return !s.observing
        }
    }

    func fire(observed: Bool) {
        let waiting: CheckedContinuation<Void, Never>? = state.withLock { s in
            if observed { s.observing = false }
            guard let continuation = s.continuation else {
                s.fired = true
                return nil
            }
            s.continuation = nil
            return continuation
        }
        waiting?.resume()
    }

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = state.withLock { s in
            if s.fired {
                s.fired = false
                return true
            }
            s.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }
}

/// A gate a test opens when it is ready: a fake engine call that waits on it stays in progress until then, so the test
/// can act while the call is running however slow the machine is.
final class TestGate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(open: Bool = false) {
        state.withLock { $0.open = open }
    }

    func open() {
        let waiters = state.withLock { s in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { s in
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
