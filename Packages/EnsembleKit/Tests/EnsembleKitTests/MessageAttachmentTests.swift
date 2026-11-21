import Foundation
import ImageIO
import Testing
@testable import EnsembleKit

/// A 1 by 1 PNG, as the CLI stores an attached picture: base64 text inside the transcript line.
private enum Sample {
    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func picture(_ mediaType: String = "image/png", _ data: String = pngBase64) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data]]
    }

    static func user(_ uuid: String, parent: String?, content: [[String: Any]]) throws -> String {
        try line(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": "2026-11-20T18:00:00.000Z",
                  "imagePasteIds": [1], "message": ["role": "user", "content": content]])
    }

    static func assistant(_ uuid: String, parent: String, text: String) throws -> String {
        try line(["type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": "2026-11-20T18:00:05.000Z",
                  "message": ["id": "msg_\(uuid)", "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    /// Two messages with pictures (one of them only a picture) and a reply.
    static func transcript() throws -> String {
        [
            try user("u1", parent: nil, content: [picture(), picture("image/webp"), ["type": "text", "text": "i cant type here. doesnt work."]]),
            try assistant("a1", parent: "u1", text: "Looking."),
            try user("u2", parent: "a1", content: [picture()]),
            try assistant("a2", parent: "u2", text: "Got it."),
            try user("u3", parent: "a2", content: [
                ["type": "text", "text": "And these"],
                ["type": "text", "text": ClaudeTranscriptBuilder.attachedFilesPrefix + "\n/tmp/proj/notes.pdf\n/tmp/proj/shot.jpg"],
            ]),
        ].joined(separator: "\n")
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Pictures and files on messages")
struct MessageAttachmentTests {
    private func userRows(_ items: [TranscriptItem]) -> [(id: String, text: String)] {
        items.compactMap { if case .user(let id, let text, _) = $0 { (id, text) } else { nil } }
    }

    // MARK: Stored Claude transcripts

    @Test func storedPicturesComeBackAsAttachmentsNotAsText() throws {
        let chain = ClaudeTranscriptFiles.parse(Data(try Sample.transcript().utf8)).activeChain()
        var builder = ClaudeTranscriptBuilder(rootID: "root", directory: "/tmp/proj", finished: true)

        // The plain transcript keeps its marker, so callers that only read text still see a picture was there.
        let plain = userRows(builder.items(from: chain))
        #expect(plain.map(\.text) == ["[image]\n\n[image]\n\ni cant type here. doesnt work.", "[image]",
                                      "And these\n\n" + ClaudeTranscriptBuilder.attachedFilesPrefix + "\n/tmp/proj/notes.pdf\n/tmp/proj/shot.jpg"])

        builder.attachmentsApart = true
        let built = builder.build(from: chain)
        let rows = userRows(built.items)
        #expect(rows.map(\.text) == ["i cant type here. doesnt work.", "", "And these"], "only what was typed")
        #expect(rows.map(\.id) == plain.map(\.id), "the same rows either way, so positions still match")
        #expect(built.attached["u1"] == [.picture(mediaType: "image/png", base64: Sample.pngBase64),
                                         .picture(mediaType: "image/webp", base64: Sample.pngBase64)])
        #expect(built.attached["u2"] == [.picture(mediaType: "image/png", base64: Sample.pngBase64)])
        #expect(built.attached["u3"] == [.file(path: "/tmp/proj/notes.pdf"), .file(path: "/tmp/proj/shot.jpg")])
        #expect(built.attached.count == 3)
    }

    @Test func aPictureWithoutBytesStaysAMarkerAndTypedTextIsNeverTakenForAFileList() throws {
        let lines = [
            try Sample.user("u1", parent: nil, content: [["type": "image", "source": ["type": "url", "url": "https://example.test/a.png"]],
                                                         ["type": "text", "text": "see"]]),
            // Typed text that starts like the file list but is not one, and a lone block that is the whole message.
            try Sample.user("u2", parent: "u1", content: [["type": "text", "text": "hi"],
                                                          ["type": "text", "text": ClaudeTranscriptBuilder.attachedFilesPrefix + "\nnot a path"]]),
            try Sample.user("u3", parent: "u2", content: [["type": "text", "text": ClaudeTranscriptBuilder.attachedFilesPrefix + "\n/tmp/a.txt"]]),
        ].joined(separator: "\n")
        var builder = ClaudeTranscriptBuilder(rootID: "root", directory: "/tmp/proj", finished: true)
        builder.attachmentsApart = true
        let built = builder.build(from: ClaudeTranscriptFiles.parse(Data(lines.utf8)).activeChain())
        #expect(userRows(built.items).map(\.text) == [
            "[image]\n\nsee",
            "hi\n\n" + ClaudeTranscriptBuilder.attachedFilesPrefix + "\nnot a path",
            ClaudeTranscriptBuilder.attachedFilesPrefix + "\n/tmp/a.txt",
        ])
        #expect(built.attached.isEmpty)
        #expect(ClaudeTranscriptBuilder.attachedFilePaths("Attached files") == nil)
    }

    #if os(macOS)
    /// The whole path for a session loaded from disk: the engine reads the CLI's file and hands back real picture files.
    @Test func theEngineCopiesStoredPicturesIntoFilesThatDecode() async throws {
        let root = try Sample.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "11111111-2222-4333-8444-555555555555"
        let projects = root.appendingPathComponent("projects")
        let folder = projects.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("\(sessionID).jsonl")
        try Data(try Sample.transcript().utf8).write(to: transcript)
        let engine = ClaudeCodeEngine(configuration: .init(executablePath: "/nonexistent/claude",
                                                            storeURL: root.appendingPathComponent("claude-sessions.json"),
                                                            projectsDirectory: projects, baseEnvironment: [:],
                                                            trust: WorkspaceTrust(fileURL: root.appendingPathComponent("trust.json"))))
        #expect(engine.configuration.pictureCacheDirectory.path == root.appendingPathComponent("pictures").path,
                "a test engine keeps its pictures in its own folder")
        let session = ClaudeImportSession(id: sessionID, directory: "/tmp/proj", title: "Pictures", titleSource: .firstPrompt,
                                          created: Date(), updated: Date(), transcriptPath: transcript.path)
        #expect(await engine.importSessions([session], permissionMode: .auto).imported == 1)

        let loaded = try await engine.attachedTranscript(sessionID)
        #expect(userRows(loaded.items).map(\.text) == ["i cant type here. doesnt work.", "", "And these"])
        let first = try #require(loaded.attachments["u1"])
        #expect(first.map(\.kind) == [.image, .image])
        #expect(first.map(\.mediaType) == ["image/png", "image/webp"])
        #expect(first.map(\.id) == ["u1:0", "u1:1"])
        for attachment in first + (loaded.attachments["u2"] ?? []) {
            let path = try #require(attachment.path)
            #expect(path.hasPrefix(root.appendingPathComponent("pictures").path))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: Sample.pngBase64))
        }
        // The copy is a real picture: ImageIO reads it, and so does the thumbnail the bubble draws.
        let path = try #require(first[0].path)
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(PictureThumbnails.load(path, maxPixel: 64)?.width == 1)
        #expect(PictureThumbnails.load(root.appendingPathComponent("missing.png").path, maxPixel: 64) == nil)

        let files = try #require(loaded.attachments["u3"])
        #expect(files.map(\.kind) == [.file, .image])
        #expect(files.map(\.name) == ["notes.pdf", "shot.jpg"])
        #expect(files.map(\.path) == ["/tmp/proj/notes.pdf", "/tmp/proj/shot.jpg"])

        // Loading again writes nothing new: the same bytes are the same file.
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pictures").path).sorted()
        #expect(before.count == 2, "two different media types of the same bytes")
        _ = try await engine.attachedTranscript(sessionID)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pictures").path).sorted() == before)
        // The plain transcript has the same rows.
        #expect(userRows(try await engine.transcript(sessionID)).map(\.id) == userRows(loaded.items).map(\.id))
        await engine.shutdown()
    }
    #endif

    // MARK: The picture cache

    @Test func thePictureCacheWritesOncePerPictureAndCleansUpOldFiles() throws {
        let folder = try Sample.temporaryFolder().appendingPathComponent("pictures")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let cache = MessagePictureCache(directory: folder)
        let first = try #require(cache.store(base64: Sample.pngBase64, mediaType: "image/png"))
        #expect(first.pathExtension == "png")
        #expect(cache.store(base64: Sample.pngBase64, mediaType: "image/png") == first)
        #expect(cache.store(base64: Sample.pngBase64, mediaType: "image/jpeg")?.pathExtension == "jpg")
        #expect(cache.store(base64: "not base64 at all!", mediaType: "image/png") == nil)
        #expect(cache.store(base64: "", mediaType: nil) == nil)

        let pasted = try #require(cache.store(data: Data([1, 2, 3])))
        #expect(pasted.lastPathComponent.hasPrefix(MessageAttachments.pastedPrefix))
        #expect(cache.store(data: Data()) == nil)
        #expect(MessageAttachments.forFiles([pasted]).first?.name == nil, "a pasted picture has no name to show")
        #expect(MessageAttachments.forFiles([pasted]).first?.label == "Picture")

        // Only files unused for longer than maxAge go.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 60 * 24 * 90)], ofItemAtPath: first.path)
        #expect(cache.prune() == 1)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: pasted.path))
    }

    // MARK: The type

    @Test func attachmentsForFilesAndTheirPlainWords() {
        let list = MessageAttachments.forFiles([URL(fileURLWithPath: "/tmp/a/Screenshot 1.PNG"), URL(fileURLWithPath: "/tmp/a/notes.md"),
                                                URL(fileURLWithPath: "/tmp/a/photo.jpeg"), URL(string: "https://example.test/x.png")!])
        #expect(list.map(\.kind) == [.image, .file, .image], "only local files; pictures by extension, any case")
        #expect(list.map(\.mediaType) == ["image/png", nil, "image/jpeg"])
        #expect(list.map(\.name) == ["Screenshot 1.PNG", "notes.md", "photo.jpeg"])
        #expect(list[0].path == "/tmp/a/Screenshot 1.PNG")
        #expect(MessageAttachments.summary(list) == "2 pictures, notes.md")
        #expect(MessageAttachments.summary([list[0]]) == "Picture")
        #expect(MessageAttachments.summary([list[1]]) == "notes.md")
        #expect(MessageAttachments.summary([]) == "")
        #expect(MessageAttachment(kind: .image).label == "Picture")
        #expect(MessageAttachment(kind: .file).label == "File")
        #expect(MessageAttachments.fileExtension(forMediaType: "image/jpeg") == "jpg")
        #expect(MessageAttachments.fileExtension(forMediaType: "IMAGE/WEBP") == "webp")
        #expect(MessageAttachments.fileExtension(forMediaType: "application/x-unknown") == "png")
        #expect(list[0].forRemote.path == nil && list[0].forRemote.name == "Screenshot 1.PNG")
    }

    @Test func decodingToleratesMissingAndUnknownFields() throws {
        let decoder = JSONDecoder()
        let bare = try decoder.decode(MessageAttachment.self, from: Data("{}".utf8))
        #expect(bare.kind == .file && bare.name == nil && bare.path == nil && !bare.id.isEmpty)
        let future = try decoder.decode(MessageAttachment.self, from: Data(#"{"id":"a","kind":"video","name":"clip.mov","length":12,"path":7}"#.utf8))
        #expect(future == MessageAttachment(id: "a", kind: .file, name: "clip.mov"))
        let full = MessageAttachment(id: "x", kind: .image, name: "a.png", mediaType: "image/png", path: "/tmp/a.png")
        #expect(try decoder.decode(MessageAttachment.self, from: JSONEncoder().encode(full)) == full)
    }

    // MARK: The remote protocol

    /// The shape of `RemoteTranscript` before attachments were added: what an older iPhone app decodes.
    private struct TranscriptBeforeAttachments: Decodable {
        var sessionID: String
        var title: String
        var items: [TranscriptItem]
        var activity: SessionActivity
        var secondOpinions: [RemoteSecondOpinion]?
    }

    private func rows() -> (items: [TranscriptItem], attachments: [String: [MessageAttachment]]) {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let items: [TranscriptItem] = [
            .user(id: "u1", text: "look at this", date: date),
            .agentText(id: "a1", text: "Looking.", agentID: nil, streaming: false),
            .user(id: "u2", text: "", date: date),
            .user(id: "u3", text: "no attachments", date: date),
        ]
        let attachments = [
            "u1": [MessageAttachment(id: "u1:0", kind: .image, mediaType: "image/png", path: "/Users/me/Library/Caches/Ensemble/pictures/ab.png")],
            "u2": [MessageAttachment(id: "u2:0", kind: .image, name: "shot.png", path: "/Users/me/Desktop/shot.png"),
                   MessageAttachment(id: "u2:1", kind: .file, name: "notes.pdf", path: "/Users/me/notes.pdf")],
            "gone": [MessageAttachment(kind: .image)],
        ]
        return (items, attachments)
    }

    @Test func thePhoneGetsNamesAndKindsNeverPathsOrBytes() throws {
        let (items, attachments) = rows()
        let remote = RemoteTranscript.remoteRows(items, attachments: attachments)
        #expect(Set(remote.attachments.keys) == ["u1", "u2"], "only rows that are in the transcript")
        #expect(remote.attachments.values.joined().allSatisfy { $0.path == nil })
        #expect(remote.attachments["u2"]?.map(\.name) == ["shot.png", "notes.pdf"])
        // A message that is only attachments carries plain words, for a phone app that knows nothing of attachments.
        #expect(remote.items[0] == items[0])
        guard case .user("u2", let standIn, _) = remote.items[2] else { Issue.record("row u2 is gone"); return }
        #expect(standIn == "Picture, notes.pdf")
        #expect(remote.items[3] == items[3])

        let transcript = RemoteTranscript(sessionID: "s", title: "T", items: remote.items, attachments: remote.attachments)
        #expect(transcript.showsText(of: "u1", text: "look at this"))
        #expect(!transcript.showsText(of: "u2", text: standIn), "the phone draws chips and leaves the stand-in words out")
        #expect(transcript.showsText(of: "u3", text: "no attachments"))
        let json = String(decoding: try RemoteCoding.encoder().encode(transcript), as: UTF8.self)
        #expect(!json.contains("/Users/me"), "no Mac path leaves the Mac")
        #expect(RemoteTranscript.remoteRows(items, attachments: [:]).attachments.isEmpty)
    }

    @Test func attachmentsRoundTripThroughTheRemoteProtocol() throws {
        let (items, attachments) = rows()
        let remote = RemoteTranscript.remoteRows(items, attachments: attachments)
        let transcript = RemoteTranscript(sessionID: "s", title: "Pictures", items: remote.items, activity: .working,
                                          attachments: remote.attachments)
        for message in [RemoteServerMessage.transcript(transcript), .update(.transcriptUpdated(transcript: transcript))] {
            let frame = RemoteServerFrame(message, replyTo: "4")
            let back = try RemoteCoding.decode(RemoteServerFrame.self, from: RemoteCoding.encode(frame))
            #expect(back == frame)
        }
        let data = try RemoteCoding.encoder().encode(transcript)
        let back = try RemoteCoding.decoder().decode(RemoteTranscript.self, from: data)
        #expect(back.attachments == remote.attachments)
        #expect(back.attachments["u2"]?.map(\.kind) == [.image, .file])
    }

    @Test func olderAndNewerAppsStillReadEachOther() throws {
        let (items, attachments) = rows()
        let remote = RemoteTranscript.remoteRows(items, attachments: attachments)
        let newer = try RemoteCoding.encoder().encode(RemoteTranscript(sessionID: "s", title: "T", items: remote.items,
                                                                       attachments: remote.attachments))
        // An older iPhone app: the new key is ignored, every row decodes, and the picture-only row has words to show.
        let old = try RemoteCoding.decoder().decode(TranscriptBeforeAttachments.self, from: newer)
        #expect(old.items.count == 4)
        #expect(old.items.contains { if case .user("u2", "Picture, notes.pdf", _) = $0 { true } else { false } })

        // An older Mac: no attachments key at all. The newer phone decodes an empty table and shows every text.
        var object = try #require(JSONSerialization.jsonObject(with: newer) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let fromOlderMac = try RemoteCoding.decoder().decode(RemoteTranscript.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(fromOlderMac.attachments.isEmpty)
        #expect(fromOlderMac.items.count == 4)
        #expect(fromOlderMac.showsText(of: "u2", text: "Picture, notes.pdf"))

        // A table this build cannot read (a future shape) costs the attachments, not the transcript.
        object["attachments"] = ["u1": "soon"]
        let odd = try RemoteCoding.decoder().decode(RemoteTranscript.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(odd.attachments.isEmpty && odd.items.count == 4)
    }

    // MARK: OpenCode and ACP

    @Test func openCodeMessageFilesBecomeAttachments() throws {
        let json = """
        [{"id": "msg_1", "type": "user", "time": {"created": 1763650000000}, "text": "look at this attachment",
          "files": [{"mime": "text/plain", "name": "hello.txt", "source": {"type": "uri", "uri": "file:///tmp/proj/hello.txt"}},
                    {"mime": "image/png", "source": {"type": "uri", "uri": "file:///tmp/proj/My%20Shot.png"}},
                    {"mime": "image/jpeg", "name": "inline.jpg", "source": {"type": "inline"}}]},
         {"id": "msg_2", "type": "user", "time": {"created": 1763650001000}, "text": "plain"}]
        """
        let messages = try JSONDecoder().decode([Wire.Message].self, from: Data(json.utf8))
        let attached = TranscriptMapper.attached(from: messages)
        #expect(userRows(attached.items).map(\.text) == ["look at this attachment", "plain"])
        let files = try #require(attached.attachments["msg_1"])
        #expect(files.map(\.kind) == [.file, .image, .image])
        #expect(files.map(\.name) == ["hello.txt", "My Shot.png", "inline.jpg"])
        #expect(files.map(\.path) == ["/tmp/proj/hello.txt", "/tmp/proj/My Shot.png", nil])
        #expect(attached.attachments["msg_2"] == nil)
        // The plain transcript still lists the names in the text.
        #expect(userRows(TranscriptMapper.items(from: messages)).first?.text.contains("Attached: hello.txt") == true)
    }

    @Test func filesSentThroughAnACPAgentStayOnTheirRow() {
        var state = ACPTranscriptState(sessionID: "s", directory: "/tmp/proj")
        let files = MessageAttachments.forFiles([URL(fileURLWithPath: "/tmp/proj/shot.png")])
        _ = state.addUser("", synthetic: false, attachments: files)
        _ = state.addUser("typed", synthetic: false)
        _ = state.addUser("a board note", synthetic: true, attachments: files)
        let rows = userRows(state.items)
        #expect(rows.map(\.text) == ["", "typed"])
        #expect(state.attachments == [rows[0].id: files], "a notice is not a message and carries nothing")
    }
}

@MainActor
@Suite("Sending pictures and files", .serialized)
struct MessageAttachmentStoreTests {
    private func userRows(_ session: SessionModel) -> [(id: String, text: String)] {
        session.items.compactMap { if case .user(let id, let text, _) = $0 { (id, text) } else { nil } }
    }

    @Test func aSentMessageShowsWhatWasTypedWithItsFilesAttached() async throws {
        let engine = PreviewEngine(seed: StoreSeed(), delayScale: 0)
        let store = SessionStore(engine: engine)
        await store.start()
        let session = try await store.newSession(directory: "/tmp/attach-demo", model: nil, permissionMode: .bypass)
        let picture = URL(fileURLWithPath: "/tmp/attach-demo/shot.png")
        let notes = URL(fileURLWithPath: "/tmp/attach-demo/notes.md")

        await store.send("  look at this \n", files: [picture, notes], to: session.id)
        var rows = userRows(session)
        #expect(rows.map(\.text) == ["look at this"], "no Attached line: the files are on the row")
        #expect(session.attachments[rows[0].id]?.map(\.name) == ["shot.png", "notes.md"])
        #expect(session.attachments[rows[0].id]?.map(\.kind) == [.image, .file])
        #expect(session.attachments[rows[0].id]?.first?.path == picture.path)

        // A message that is only a picture still gets its row.
        try await waitForIdle(session)
        await store.send("", files: [picture], to: session.id)
        rows = userRows(session)
        #expect(rows.map(\.text) == ["look at this", ""])
        #expect(session.attachments[rows[1].id]?.count == 1)

        // Loading the session again reads the engine's own rows and their attachments, with no doubled message.
        try await waitForIdle(session)
        await store.loadSession(session.id)
        rows = userRows(session)
        #expect(rows.map(\.text) == ["look at this", ""])
        #expect(session.attachments[rows[0].id]?.map(\.name) == ["shot.png", "notes.md"])
        #expect(session.attachments[rows[1].id]?.map(\.name) == ["shot.png"])
        let fromEngine = try await engine.attachedTranscript(session.id)
        #expect(Set(fromEngine.attachments.keys) == Set(rows.map(\.id)))
    }

    @Test func seededAttachmentsLandOnTheirSession() {
        let store = SessionStore(engine: PreviewEngine(seed: StoreSeed(), delayScale: 0))
        let files = [MessageAttachment(id: "p", kind: .image, name: "a.png", path: "/tmp/a.png")]
        store.seed(StoreSeed(sessions: [EngineSession(id: "one", title: "One", directory: "/tmp/p"),
                                        EngineSession(id: "two", title: "Two", directory: "/tmp/p")],
                             transcripts: ["one": [.user(id: "row", text: "", date: Date())], "two": [.user(id: "other", text: "x", date: Date())]],
                             attachments: ["row": files]))
        #expect(store.session("one")?.attachments == ["row": files])
        #expect(store.session("two")?.attachments.isEmpty == true)
    }

    /// Waits until the turn has ended and stays ended (the last events of a turn can trail its idle state).
    private func waitForIdle(_ session: SessionModel) async throws {
        var quiet = 0
        for _ in 0..<9000 where quiet < 8 {
            quiet = session.isWorking ? 0 : quiet + 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isWorking)
    }
}
