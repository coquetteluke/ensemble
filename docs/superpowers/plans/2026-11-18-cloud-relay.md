# Ensemble Cloud Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iPhone remote reaches the Mac from any network after one QR scan, through a Cloudflare relay that only ever carries sealed bytes.

**Architecture:**
- **Relay:** a Cloudflare Worker routes WebSocket upgrades to one Durable Object per paired Mac (a "mailbox").
  - The Mac keeps a hibernated control socket there. For each phone that proves it holds the pairing code, the Mac opens a data socket, and the object forwards frames between the two unchanged.
- **Encryption:** the existing Ensemble handshake runs end to end inside that pipe. Protocol 4 adds a fresh X25519 key exchange per connection, so recorded traffic stays sealed even if the pairing code leaks.

**Tech Stack:**
- **Relay:** TypeScript on Cloudflare Workers (Durable Objects with SQLite storage, the WebSocket Hibernation API, WebCrypto), with wrangler and vitest through `@cloudflare/vitest-pool-workers`.
- **Apps:** Swift 6 with CryptoKit and Network.framework on the Mac, and URLSession WebSockets on the iPhone.

**Spec:** `docs/superpowers/specs/2026-11-18-cloud-relay-design.md` (approved by Luke on 2026-11-18).

## Global Constraints

- No em dashes anywhere: code, comments, UI text, docs, commits.
- No third-party Swift packages. npm packages are allowed inside `relay/` only, as dev dependencies, pinned to exact versions.
- No secrets in the repo:
  - `wrangler.toml` has no `account_id`.
  - Tests build keys at runtime (see `FakeSecret` in the Swift tests).
  - The commit hook blocks secret-shaped strings, and an "allow" marker is never added.
- The default relay URL is `wss://relay.coquettemc.com`, and it lives in one constant: `RelayDefaults.url`.
- Workers free plan only: SQLite-backed Durable Objects (`new_sqlite_classes`), with no paid-only features.
- Relay logging stays off: `observability.enabled = false`, and no `console.log` of IDs, IPs or frames.
- A Claude subscription serves only its owner. Nothing here shares a Mac between people.
- Deploys to Luke's Cloudflare account happen only after he runs `npx wrangler login` himself and confirms each deploy.
- Swift 6 strict concurrency, `xcodegen` after adding files, and macOS 26 / iOS 26 targets.
- Commit messages use a plain-language subject and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Spawn-heavy Swift tests run as background commands. Foreground runs in this sandbox fail with "Permission denied".

## Wire format (shared by every task)

**Routes** (anything else gets a 404; a non-upgrade request gets a 426):
- `GET /v1/mailbox/<id>/host` (the Mac's control socket)
- `GET /v1/mailbox/<id>/phone` (a phone)
- `GET /v1/mailbox/<id>/data/<conn>` (a Mac data socket for one phone)

**Identifiers:**
- `<id>` matches `^[A-Za-z0-9_-]{43}$` (32 random bytes, base64url without padding).
- `<conn>` matches `^[A-Za-z0-9_-]{22}$` (16 bytes).

**Control frames** are JSON text frames, each at most 2 KiB. Every key is listed here; any other frame on a control socket closes it with 4002.

| Direction | Frame |
|---|---|
| relay to host or phone, on connect | `{"t":"challenge","nonce":"<b64url 32>"}` |
| host to relay, first time | `{"t":"claim","hostKey":"<b64url 32, Ed25519 public>","accessKey":"<b64url 32>","sig":"<b64url 64>"}` |
| host to relay, later | `{"t":"auth","sig":"<b64url 64>"}` |
| relay to host | `{"t":"ready"}` |
| relay to host | `{"t":"phone","conn":"<conn>","token":"<b64url 32>"}` |
| host to relay, first frame on a data socket | `{"t":"data","token":"<b64url 32>"}` |
| host to relay | `{"t":"badHandshake","conn":"<conn>"}` |
| phone to relay | `{"t":"access","proof":"<b64url 32>"}` |
| relay to phone | `{"t":"waiting"}`, then `{"t":"paired"}` |
| relay to anyone | `{"t":"limit","kind":"daily","resetsAt":<unix seconds>}` |
| relay to anyone | `{"t":"error","code":"<code>","message":"<text>"}` with code `macOffline`, `unauthorized`, `taken`, `busy`, `tooBig` or `limit` |

**Signatures and proofs:**
- The host signature is Ed25519 over the UTF-8 text `ensemble-relay-host|<id>|<nonce>`.
- The phone proof is HMAC-SHA256 under the access key, over `ensemble-relay-phone|<id>|<nonce>`.
- The access key is `HKDF-SHA256(ikm: token UTF-8, salt: "ensemble-relay", info: "ensemble-relay-access", 32 bytes)`.

**Forwarding:** after `paired`, every frame (text or binary) goes between that phone socket and its data socket unchanged. A phone frame before `paired` closes the phone with 4002.

**Size caps:**
- Phone to Mac: 1 MiB per frame.
- Mac to phone: 16 MiB, or the platform limit if that is lower. Check it in Task 1 and record it in `docs/reference/relay-notes.md`.

**Close codes:** 4001 unauthorized, 4002 protocol, 4004 no such mailbox, 4008 timeout, 4009 taken, 4010 Mac offline, 4013 too big, 4029 limit.

**Channel binding:** for relay connections, the hello's `dialedHost` is `relay:<relay host>/<id>` and `dialedPort` is 443.

## Review Focus

1. **A transcript larger than 1 MiB from Mac to phone** must arrive whole through the relay, because the phone already accepts 64 MiB. Test: a 5 MiB Mac-to-phone frame is forwarded byte for byte (Task 2).
2. **A phone that connects while the Mac's control socket is down** gets `macOffline` and close 4010, and the phone shows "Your Mac is not connected to the relay" instead of spinning. Tests in Task 2 (relay) and Task 7 (client state).
3. **A Durable Object that hibernates between "phone waiting" and the Mac's data socket** still pairs them. The pairing state lives in socket attachments, not memory. Test in Task 2, using `runDurableObjectAlarm` or a forced eviction.
4. **The phone switching from Wi-Fi to cellular mid-session** drops the socket, then reconnects through the relay on its own and reloads state. Test in Task 7 with a fake relay that drops the first connection.
5. **The Mac's per-address handshake limiter** must key relayed phones by relay connection id. Otherwise five failed strangers block every relayed phone. Test in Task 5.

---

### Task 1: Relay project, mailbox claim and host authentication

**Files:**
- Create: `relay/package.json`, `relay/wrangler.toml`, `relay/tsconfig.json`, `relay/vitest.config.ts`
- Create: `relay/src/index.ts`, `relay/src/mailbox.ts`, `relay/src/wire.ts`
- Create: `relay/README.md` (deploying your own relay)
- Create: `docs/reference/relay-notes.md`
- Test: `relay/test/host.test.ts`

**Interfaces:**
- Produces in `relay/src/wire.ts`:
  - `parseControl(text: string): ControlFrame | null`, where `ControlFrame` is a tagged union of the table above.
  - `isMailboxID(s: string): boolean`, `isConnID(s: string): boolean`.
  - `b64url(bytes: Uint8Array): string`, `fromB64url(s: string): Uint8Array | null`.
- Produces in `relay/src/mailbox.ts`: `export class Mailbox extends DurableObject`, with storage keys `hostKey`, `accessKey`, `lastUsed`. `relay/src/index.ts` routes to `env.MAILBOX.getByName(id)`.

- [ ] **Step 1: Scaffold.**
  - `package.json` with exact versions of `wrangler`, `vitest`, `@cloudflare/vitest-pool-workers` and `@cloudflare/workers-types` (take each from `npm view <pkg> version`).
  - `wrangler.toml`:
    - `name = "ensemble-relay"`, `main = "src/index.ts"`, today's `compatibility_date`.
    - A durable object binding `MAILBOX` of class `Mailbox`, with migration `new_sqlite_classes = ["Mailbox"]`.
    - `[observability] enabled = false`.
    - `routes = [{ pattern = "relay.coquettemc.com", custom_domain = true }]`.
  - Run `cd relay && npm install` and check that `npx wrangler types` succeeds.
- [ ] **Step 2: Write the failing tests** in `relay/test/host.test.ts` (through `SELF.fetch` with WebSocket upgrades):
  - `rejects unknown routes`: `GET /v1/nope` gives 404, a non-upgrade `GET /v1/mailbox/<id>/host` gives 426, and a bad id gives 404.
  - `claims an unclaimed mailbox`:
    - Connect `/host`, receive `challenge`, then send `claim` with a fresh Ed25519 key, a 32-byte access key and a valid signature. Expect `ready`.
    - A second connection signing with the same key gets `ready` after `auth`.
  - `refuses a wrong signature`: `auth` signed by another key closes with 4001.
  - `refuses a second claim`: `claim` on a claimed mailbox with a different key closes with 4009.
  - `only one control socket`: a newer authenticated host socket closes the older one with 4009.
- [ ] **Step 3: Run `cd relay && npx vitest run test/host.test.ts`.** Expected: FAIL.
- [ ] **Step 4: Implement the routing, the challenge, claim and auth (WebCrypto Ed25519 verify), and host socket replacement.**
  - Accept with `ctx.acceptWebSocket(ws, ["host"])` and `ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"))`.
  - Keep the challenge nonce in `serializeAttachment`.
- [ ] **Step 5: Run the tests.** Expected: PASS. Write the platform's real WebSocket message size limit, the free-plan numbers and the hibernation notes into `docs/reference/relay-notes.md`.
- [ ] **Step 6: Commit** `relay/` and the notes: "Relay: Cloudflare Worker with mailbox claim and host sign-in".

### Task 2: Phone access, pairing and forwarding

**Files:**
- Modify: `relay/src/mailbox.ts`
- Test: `relay/test/forward.test.ts`

**Interfaces:**
- Consumes: Task 1's `wire.ts` and the claimed mailbox state.
- Produces socket tags `phone:<conn>` and `data:<conn>`, and attachments `{role, conn, nonce?, paired, ip}`.

- [ ] **Step 1: Write the failing tests:**
  - `a phone with the right proof is paired`: host claimed; phone connects, receives `challenge`, sends `access` with a valid HMAC, and receives `waiting`.
    - The host receives `phone` with `conn` and `token`.
    - The host opens `/data/<conn>` and sends `data` with the token.
    - The phone receives `paired`.
    - Then `phone -> "hello"` arrives on data as `"hello"`, and binary `[1,2,3]` from data arrives at the phone.
  - `a wrong proof is refused`: close 4001, and the host gets no `phone` frame.
  - `mac offline`: no host socket; the phone gets `error macOffline` and close 4010.
  - `a data socket with a wrong token is refused`: close 4001.
  - `frames before paired close the phone`: close 4002.
  - `either side closing closes the other`.
  - `pairing survives hibernation`: evict the object between `phone` and `data` (the test helper from vitest-pool-workers), and the pair still forms.
  - `a large mac frame passes`: a 5 MiB binary frame from data arrives whole at the phone. A 1 MiB + 1 frame from the phone closes it with 4013.
- [ ] **Step 2: Run `npx vitest run test/forward.test.ts`.** Expected: FAIL.
- [ ] **Step 3: Implement** the phone challenge and proof check against the stored access key, the `phone` notice with a single-use token held in the phone socket's attachment, the data socket match by token, forwarding by tag lookup in `webSocketMessage`, and the size caps from the wire format.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit:** "Relay: phones prove the pairing code, then frames pass through unchanged".

### Task 3: Relay limits and clean-up

**Files:**
- Modify: `relay/src/mailbox.ts`, `relay/src/index.ts`, `relay/wrangler.toml`
- Test: `relay/test/limits.test.ts`

**Interfaces:**
- Produces in `relay/src/limits.ts` (create it): the constants `MAX_PHONES = 8`, `MAX_WAITING = 3`, `PAIR_TIMEOUT_MS = 15000`, `DAILY_MESSAGES = 40000`, `DAILY_BYTES = 200 * 1024 * 1024`, `FAILURES_BEFORE_BLOCK = 5`, `BLOCK_MS = 15 * 60 * 1000`, `IDLE_DELETE_MS = 90 * 24 * 3600 * 1000`, and `CLAIMS_PER_IP_PER_HOUR = 10`.

- [ ] **Step 1: Write the failing tests:**
  - `at most 8 phones and 3 waiting`: the ninth paired phone or the fourth waiting one gets `error busy` and close 4029.
  - `waiting phones time out`: no data socket within 15 s means close 4008. Use the fake timers the pool supports, or an alarm.
  - `bad handshakes block an ip`: the host sends `badHandshake` for 5 connections from the same `CF-Connecting-IP`. The next phone from that IP gets close 4001 without a `phone` notice, and another IP still works.
  - `daily budget`: past 40,000 incoming messages or 200 MB in one UTC day, both sides get a `limit` frame with `resetsAt` at the next 00:00 UTC, and close 4029. Counters are written to storage at most once a minute (assert the storage write count).
  - `claim rate per ip`: the eleventh claim within an hour from one IP gets close 4029.
  - `idle mailboxes are deleted`: an alarm 90 days after `lastUsed` deletes the storage, and the next `auth` gets close 4004.
- [ ] **Step 2: Run `npx vitest run test/limits.test.ts`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The claim rate limit uses the Workers rate limiting binding if the free plan has it (check in the docs). Otherwise use a small `ClaimLimiter` Durable Object keyed by IP.
  - Failure counts live in memory only.
- [ ] **Step 4: Run all relay tests with `npx vitest run`.** Expected: PASS.
- [ ] **Step 5: Commit:** "Relay: per-Mac limits, daily budget, claim rate and idle clean-up".

### Task 4: Protocol 4, a fresh key exchange per connection

**Files:**
- Modify: `Packages/EnsembleKit/Sources/EnsembleKit/Remote/RemoteAuth.swift`, `RemoteChannel.swift`, `RemoteMessages.swift`, `RemoteProtocol.swift`, `RemoteServer.swift` (`peerReady`, `handleHello`), `RemoteClient.swift` (`handshake`)
- Test: `Packages/EnsembleKit/Tests/EnsembleKitTests/RemoteProtocolTests.swift`, `RemoteLoopbackTests.swift`

**Interfaces:**
- `remoteProtocolVersion = 4`, `remoteMinimumProtocolVersion = 4`.
- `RemoteChallenge.ephemeralKey: String` and `RemoteHello.ephemeralKey: String`: a Curve25519.KeyAgreement public key, raw 32 bytes, base64url.
- `RemoteHandshake.clientProof(token:serverNonce:clientNonce:macKey:phoneKey:) -> Data` is HMAC over `serverNonce || clientNonce || macKey || phoneKey || "ensemble-client"`.
- `RemoteHandshake.serverProof(token:serverNonce:clientNonce:macKey:phoneKey:) -> Data` is HMAC over `clientNonce || serverNonce || phoneKey || macKey || "ensemble-server"`. Both have matching `isValid...` checks.
- `RemoteChannel.init(token:sharedSecret:serverNonce:clientNonce:dialedHost:dialedPort:role:protocolVersion:)`: the HKDF input key material is `token UTF-8 || sharedSecret` (32 bytes). Salt and info are unchanged.

- [ ] **Step 1: Write the failing tests in `RemoteProtocolTests`:**
  - `proofsCoverBothEphemeralKeys`: changing either key makes `isValidClientProof` and `isValidServerProof` false.
  - `recordedFramesNeedTheSharedSecret`: a frame sealed with token A plus secret S does not open with token A plus secret S2.
  - `versionThreeIsRefused`: a hello with `protocolVersion: 3` gets `unsupportedVersion`.
  - Update the existing proof and channel tests to the new signatures.
- [ ] **Step 2: Run `swift test --filter RemoteProtocolTests`** in the background. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - The Mac makes a key pair in `peerReady`, keeps the private key on the `Peer`, and drops it after `handleHello`.
  - The phone makes one per handshake.
  - A missing or malformed `ephemeralKey` gets `badRequest` and the connection closes.
- [ ] **Step 4: Run `RemoteProtocolTests` and `RemoteLoopbackTests`.** Expected: PASS.
- [ ] **Step 5: Commit:** "Remote protocol 4: a fresh key exchange on every connection".

### Task 5: Relay identity, pairing code and the Mac's relay host

**Files:**
- Create: `Packages/EnsembleKit/Sources/EnsembleKit/Remote/RelayWire.swift` (Codable control frames, matching the table)
- Create: `Packages/EnsembleKit/Sources/EnsembleKit/Remote/RelayIdentity.swift`
- Create: `Packages/EnsembleKit/Sources/EnsembleKit/Remote/RelayHost.swift` (`#if os(macOS)`)
- Modify:
  - `RemoteProtocol.swift`: `RemotePairing.relay`, and hosts may be empty when `relay` is set.
  - `RemoteServer.swift`: `adopt(_:relayConnection:)`, accepting the relay identity in `isOwnAddress`, and a limiter key per relay connection.
- Test: `RelayIdentityTests.swift`, `RelayHostTests.swift`

**Interfaces:**
- `public struct RemotePairing.Relay: Codable, Hashable, Sendable { public var url: String; public var mailbox: String }`, plus `public var relay: Relay?` and `public var previousRelay: Relay?` on `RemotePairing`.
- `public enum RelayDefaults { public static let url = "wss://relay.coquettemc.com" }`
- `public struct RelayIdentity: Sendable`, with:
  - `mailboxID: String` and `hostKey: Curve25519.Signing.PrivateKey`;
  - `static func make() -> RelayIdentity`;
  - `static func accessKey(token: String) -> SymmetricKey`;
  - `static func channelHost(relayURL: URL, mailboxID: String) -> String`, returning `relay:<host>/<id>`;
  - `static func hostSignaturePayload(mailboxID: String, nonce: String) -> Data`;
  - `static func phoneProof(accessKey: SymmetricKey, mailboxID: String, nonce: String) -> Data`.
- `public struct RelayIdentityStore`: keychain service `RemoteKeychain.defaultService`, account `relay-identity`. It saves the mailbox ID and the raw host key, and regenerating the pairing code replaces the identity.
- `public actor RelayHost`, with `init(relayURL: URL, identity: RelayIdentity, token: String, server: RemoteServer)`, `start()`, `stop()` and `statusUpdates() -> AsyncStream<RelayHostStatus>`.
- `public enum RelayHostStatus: Equatable, Sendable { case off, connecting, connected, unreachable(String), limitReached(resetsAt: Date?), mailboxTaken }`
- `RemoteServer.adopt(_ connection: NWConnection, relayConnection id: String)`: the same `Peer` path as `accept`, with address `relay:<id>`.

- [ ] **Step 1: Write the failing tests:**
  - `RelayIdentityTests`:
    - The access key is stable for one token and different for another.
    - The proof and signature payloads match fixed vectors made with the TypeScript functions. Copy the hex from a `relay/test/vectors.test.ts` run into the Swift test as runtime-built strings.
    - `channelHost` for `wss://relay.coquettemc.com` and id X is `relay:relay.coquettemc.com/X`.
    - A pairing code with `relay` and no hosts decodes, while one with neither throws `missingHosts`.
  - `RelayHostTests`, against a local fake relay written with Network.framework in the test target (`FakeRelay`, speaking the wire format):
    - It claims on first start and authenticates on the second.
    - A `phone` notice opens a data socket, and the adopted connection completes a protocol 4 handshake with a test client.
    - A bad handshake on an adopted connection sends `badHandshake`.
    - Five failed relayed phones don't block a sixth good one (Review Focus 5).
    - A `limit` frame sets `limitReached`.
    - When the relay has forgotten the mailbox (close 4004 on `auth`, after the 90-day clean-up or a redeploy), the host claims the same ID again with the same key and reaches `connected`.
    - A close 4009 on `claim` (the ID is held by another key) sets `mailboxTaken`.
- [ ] **Step 2: Run them** in the background. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `RelayHost` uses `NWConnection` with `NWProtocolWebSocket.Options`, over TLS to the relay. In tests, plain `ws://` is allowed only for `127.0.0.1`.
  - It reconnects with backoff of 1, 2, 4 and 8 s, capped at 60 s.
- [ ] **Step 4: Run** the new tests and the whole `Remote*` suites. Expected: PASS.
- [ ] **Step 5: Commit:** "Remote: the Mac keeps a mailbox on the relay and serves phones through it".

### Task 6: Relay details reach phones, and the relay can move

**Files:**
- Modify: `RemoteMessages.swift` (add `RemoteServerMessage.relayDetails(RemotePairing.Relay)`), `RemoteServer.swift` (send it after `welcome`), `RemoteClient.swift` (save it)
- Test: `RemoteLoopbackTests.swift`

**Interfaces:**
- `RemoteClient` updates its stored pairing through `RemotePairingStore.save`. A new relay becomes `relay`, and the old one becomes `previousRelay` until a connection through the new one succeeds.

- [ ] **Step 1: Write the failing tests:**
  - `relayDetailsAreSavedAfterWelcome`.
  - `previousRelayIsTriedWhenTheNewOneFails`.
  - `previousRelayIsDroppedAfterTheNewOneWorks`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** The relay details travel only inside the sealed channel, never in plaintext.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit:** "Remote: phones learn the Mac's relay over the sealed channel".

### Task 7: The phone dials direct and relay at once

**Files:**
- Create: `Packages/EnsembleKit/Sources/EnsembleKit/Remote/RelayDialer.swift`
- Modify: `RemoteClient.swift` (`runLoop` races the paths, and the state gains `.connected(via:)`), `Apps/iOS` status text
- Test: `RemoteRelayClientTests.swift`

**Interfaces:**
- `enum RelayDialer { static func connect(relay: RemotePairing.Relay, token: String, session: URLSession, timeout: Duration) async throws -> URLSessionWebSocketTask }`
  - It returns after `paired`.
  - It throws `RemoteError(.macOffline, ...)` on `macOffline` (add that code to `RemoteError.Code`), and `RemoteError(.limit, ...)` on `limit`.
- `RemoteConnectionPath: Equatable, Sendable { case direct(host: String), relay }`.
- Race rule: start every direct host and the relay together. Take a direct connection if it completes within 300 ms of the relay; otherwise take the relay. Cancel the losers.

- [ ] **Step 1: Write the failing tests**, with `FakeRelay` from Task 5 and a loopback `RemoteServer`:
  - `relayOnlyPairingConnects`.
  - `directWinsWhenBothWork`.
  - `relayWinsWhenDirectIsUnreachable`.
  - `macOfflineShowsItsOwnState`, where the state text is "Your Mac is not connected to the relay" (Review Focus 2).
  - `reconnectsThroughTheRelayAfterADrop` (Review Focus 4).
  - `wrongPairingCodeIsRefusedByTheRelay` (an unauthorized close 4001 is reported as a refusal).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.** The Ensemble handshake runs unchanged on the returned task, with `dialedHost = RelayIdentity.channelHost(...)` and `dialedPort = 443`.
- [ ] **Step 4: Run them and all `Remote*` suites.** Expected: PASS. Build `EnsembleRemote` for the iOS Simulator.
- [ ] **Step 5: Commit:** "iPhone: reaches the Mac directly or through the relay, whichever answers first".

### Task 8: Mac settings, the QR code, and turning it on

**Files:**
- Modify: `Apps/Mac/Remote/RemoteControlController.swift`, `Apps/Mac/Remote/RemotePairingView.swift`, the Remote section of `Apps/Mac/Settings/` (find it with `grep -rn "Remote" Apps/Mac/Settings`)
- Create: `Apps/Mac/Snapshots/RelaySnapshots.swift`, with one line added in `SnapshotRenderer.swift`

**Interfaces:**
- Consumes `RelayHost`, `RelayIdentityStore` and `RelayDefaults`.
- UserDefaults keys `remoteRelayEnabled` (default `true`) and `remoteRelayURL` (default `RelayDefaults.url`).

- [ ] **Step 1: Wire `RelayHost` into the controller.**
  - Start and stop it with Remote and the toggle.
  - Put `relay` in the pairing, so the QR code always shows when the relay is on.
  - Make `regenerateCode()` also replace the relay identity.
  - `mailboxTaken` makes a new identity and shows "Scan the new pairing code".
  - **Changing the relay address:** the controller keeps a second `RelayHost` on the old address for 30 days (UserDefaults `remoteRelayPreviousURL` and `remoteRelayPreviousUntil`), so phones that haven't connected since still reach the Mac and learn the new address (Task 6). After 30 days it stops.
- [ ] **Step 2: Settings UI:**
  - A "Connect from anywhere (end-to-end encrypted)" toggle.
  - A "Relay address" field under an "Advanced" disclosure, which accepts `wss://` only, plus `ws://127.0.0.1` in Debug.
  - A status line: "Connected through the relay", "Relay unreachable", "Daily relay limit reached, resets at <time>" or "This relay address is in use by another Mac".
- [ ] **Step 3: Snapshots** of the section in each status and the QR view, dark and light, at 100% and 150%. Render them with `--render-snapshots`, look at them, and fix what looks off.
- [ ] **Step 4: Run** `xcodegen`, both schemes, and the full `swift test` in the background. Expected: all pass.
- [ ] **Step 5: Commit:** "Remote: connect from anywhere through the relay, on by default".

### Task 9: Docs, a local end-to-end run, and the first deploy

**Files:**
- Modify: `docs/DESIGN.md` (a "Cloud relay" section), `docs/PROGRESS.md`, `relay/README.md`
- Create: `docs/reference/relay-privacy.md` (what the relay sees and keeps)
- Test: `Packages/EnsembleKit/Tests/EnsembleKitTests/RelayLiveTests.swift`, behind `ENSEMBLE_LIVE_RELAY=1` and `ENSEMBLE_RELAY_URL`

- [ ] **Step 1: Write `RelayLiveTests.endToEndThroughWranglerDev`.**
  - Start `npx wrangler dev --local --port 8787` in `relay/` from the test, or expect it to be running.
  - A real `RelayHost` and `RemoteClient` pair through `ws://127.0.0.1:8787`.
  - A transcript round trip and a 5 MiB frame both arrive.
- [ ] **Step 2: Run it** with `ENSEMBLE_LIVE_RELAY=1 ENSEMBLE_RELAY_URL=ws://127.0.0.1:8787 swift test --filter RelayLiveTests` in the background. Expected: PASS.
- [ ] **Step 3: Write the docs.** The privacy note says plainly what Cloudflare can see: IPs, timing, sizes and mailbox IDs in paths. It also says what nobody can read: content, the pairing code and the Mac name.
- [ ] **Step 4: Commit:** "Docs: cloud relay design notes, privacy, and running your own".
- [ ] **Step 5: First deploy, with Luke.**
  - Ask him to run `cd relay && npx wrangler login` in his browser.
  - After his yes, run `npx wrangler deploy`.
  - Check `wss://relay.coquettemc.com/v1/nope` returns 404.
  - Install the Mac build (`scripts/install-mac.sh`) and the iPhone build (`scripts/ios-resign-weekly.sh --force` from a clean copy of HEAD).
  - Test on the Duo with Wi-Fi off.
