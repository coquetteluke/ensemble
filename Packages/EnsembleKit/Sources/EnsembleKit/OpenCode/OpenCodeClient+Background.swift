import Foundation

// MARK: Background work

/// OpenCode 2.3 runs a shell tool call with `background: true` as a background job, listed by
/// `GET /api/experimental/job` (`kind` shell, subagent or image; `status` running, completed, error or cancelled; no
/// location needed) and ended by `DELETE /api/shell/{shellID}` in the session's location, which kills the process.
/// Subagents are child sessions; `POST /api/session/{child}/interrupt` ends only the child (its parent then gets a
/// `<subagent>` report saying it was interrupted). All three were checked live with the mock model on 2026-11-18.
extension OpenCodeClient: EngineBackgroundTasks {
    private struct JobList: Decodable {
        var data: [Job]
    }

    private struct Job: Decodable {
        struct Time: Decodable {
            var started: Double
        }

        var kind: String
        var id: String
        var sessionID: String
        var status: String
        var title: String?
        var time: Time
        var shellID: String?
        var command: String?
    }

    public func backgroundTasks() async throws -> [BackgroundTask] {
        let list: JobList = try await get("/api/experimental/job", query: [URLQueryItem(name: "kind", value: "shell"),
                                                                          URLQueryItem(name: "status", value: "running")])
        return list.data.compactMap { job in
            guard job.kind == "shell", job.status == "running" else { return nil }
            let command = job.command ?? job.title ?? ""
            return BackgroundTask(id: job.shellID ?? job.id, sessionID: job.sessionID, kind: .shell, title: command,
                                  started: Date(timeIntervalSince1970: job.time.started / 1000))
        }
    }

    public func stopBackgroundTask(_ task: BackgroundTask) async throws {
        let directory = try await session(task.sessionID).directory
        try await sendIgnoringBody("DELETE", "/api/shell/\(Self.pathComponent(task.id))", query: Self.location(directory))
    }

    public func stopSubagent(_ sessionID: String) async throws {
        try await interrupt(sessionID)
    }
}
