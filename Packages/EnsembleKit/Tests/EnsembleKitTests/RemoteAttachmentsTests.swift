import EnsembleKit
import Foundation
import Testing

@Suite("Remote mobile attachment uploads")
struct RemoteAttachmentsTests {
    @Test func filenameAndUploadIDValidationBlocksTraversal() {
        #expect(RemoteAttachments.isValidUploadID(UUID().uuidString.lowercased()))
        #expect(!RemoteAttachments.isValidUploadID("../escape"))
        #expect(!RemoteAttachments.isValidUploadID("short"))
        #expect(!RemoteAttachments.isValidUploadID("bad/slash/id"))

        #expect(RemoteAttachments.sanitizeFilename("../../etc/passwd", kind: .file) == "passwd")
        #expect(RemoteAttachments.sanitizeFilename("...hidden.txt", kind: .file) == "hidden.txt")
        #expect(RemoteAttachments.sanitizeFilename("", kind: .image) == "photo.jpg")
        #expect(RemoteAttachments.sanitizeFilename("screenshot", kind: .image) == "screenshot.jpg")
        #expect(RemoteAttachments.sanitizeFilename("shot.png", kind: .image) == "shot.png")
    }

    @Test func inboxReassemblesMultiChunkUploadAndClaimsOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-att-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inbox = RemoteAttachmentInbox(directory: dir)
        let payload = Data((0..<(RemoteAttachments.chunkSize * 2 + 1234)).map { UInt8($0 % 251) })
        let uploadID = UUID().uuidString.lowercased()

        var offset = 0
        while offset < payload.count {
            let end = min(offset + RemoteAttachments.chunkSize, payload.count)
            try await inbox.receive(RemoteAttachmentChunk(
                uploadID: uploadID,
                name: "../nested/report.pdf",
                kind: .file,
                offset: offset,
                totalBytes: payload.count,
                data: payload.subdata(in: offset..<end)
            ))
            offset = end
        }

        let claimed = try await inbox.claim([uploadID])
        #expect(claimed.count == 1)
        #expect(claimed[0].name == "report.pdf")
        #expect(claimed[0].kind == .file)
        #expect(claimed[0].url.path.hasPrefix(dir.path))
        #expect(try Data(contentsOf: claimed[0].url) == payload)

        // Second claim of the same upload id must fail.
        await #expect(throws: RemoteError.self) {
            _ = try await inbox.claim([uploadID])
        }
    }

    @Test func inboxRejectsIncompleteOutOfOrderAndOversizedChunks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-att-err-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inbox = RemoteAttachmentInbox(directory: dir)
        let id = UUID().uuidString.lowercased()

        // Oversized totalBytes rejected.
        await #expect(throws: RemoteError.self) {
            try await inbox.receive(RemoteAttachmentChunk(
                uploadID: id,
                name: "huge.bin",
                kind: .file,
                offset: 0,
                totalBytes: RemoteAttachments.maxFileBytes + 1,
                data: Data([1, 2, 3])
            ))
        }

        // Start a 10-byte upload with 4 bytes.
        try await inbox.receive(RemoteAttachmentChunk(
            uploadID: id,
            name: "notes.txt",
            kind: .file,
            offset: 0,
            totalBytes: 10,
            data: Data([1, 2, 3, 4])
        ))

        // Out-of-order offset rejected.
        await #expect(throws: RemoteError.self) {
            try await inbox.receive(RemoteAttachmentChunk(
                uploadID: id,
                name: "notes.txt",
                kind: .file,
                offset: 6,
                totalBytes: 10,
                data: Data([7, 8, 9, 10])
            ))
        }

        // Claiming before complete rejected.
        await #expect(throws: RemoteError.self) {
            _ = try await inbox.claim([id])
        }
    }

    @Test func legacySendMessageDecodesWithoutAttachmentIDs() throws {
        let json = #"{"target":{"kind":"session","id":"s1"},"text":"hello"}"#
        let decoded = try JSONDecoder().decode(RemoteSendMessage.self, from: Data(json.utf8))
        #expect(decoded.text == "hello")
        #expect(decoded.attachmentIDs == nil)
    }

    @Test @MainActor func clientUploadsMultiChunkPhotoAndSendsAttachmentOnlyMessage() async throws {
        let host = DemoRemoteHost(data: .sample())
        let client = RemoteClient(inProcessHost: host, macName: "Test Mac")
        client.start()
        defer { client.stop() }

        for _ in 0..<40 where !client.state.isConnected || client.sessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let sessionID = try #require(client.sessions.first?.id)
        try await client.open(sessionID: sessionID)

        // 400 KB photo -> spans 3 chunks at 192 KB each.
        let photoBytes = Data(repeating: 0xAB, count: 400_000)
        let photoID = try await client.uploadAttachment(name: "IMG_001.jpg", kind: .image, data: photoBytes)
        try await client.send("", to: .session(sessionID), attachmentIDs: [photoID])

        for _ in 0..<40 {
            if let t = client.openTranscript, !t.attachments.values.flatMap({ $0 }).filter({ $0.name == "IMG_001.jpg" }).isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let transcript = try #require(client.openTranscript)
        let lastUser = try #require(transcript.items.reversed().first {
            if case .user = $0 { return true }
            return false
        })
        let attached = transcript.attachments[lastUser.id] ?? []
        #expect(attached.count == 1)
        #expect(attached[0].kind == .image)
        #expect(attached[0].name == "IMG_001.jpg")

        // Preview fetch returns the uploaded image bytes for display on iPhone/iPad.
        let preview = try await client.attachmentPreview(sessionID: sessionID, attachmentID: attached[0].id)
        #expect(preview.attachmentID == attached[0].id)
        #expect(preview.data == photoBytes)
    }
}
