# Relay platform notes (Cloudflare Workers and Durable Objects)

Checked on 2026-11-18 against developers.cloudflare.com.

## WebSocket message size

- A Durable Object accepts WebSocket messages of up to 32 MiB (33,554,432 bytes), "only for received messages". Same limit on Free and Paid.
  Source: https://developers.cloudflare.com/durable-objects/platform/limits/
- The relay's caps (1 MiB phone to Mac, 16 MiB Mac to phone) are both under 32 MiB, so the platform limit does not lower either cap. The relay enforces the caps itself and closes with 4013.
- The WebSockets best-practices page does not state a message limit; the limits page above is the source.

## Free plan numbers (SQLite-backed Durable Objects only)

Source: https://developers.cloudflare.com/durable-objects/platform/pricing/

- 100,000 requests per day
- 13,000 GB-s duration per day
- 5 million SQLite rows read per day
- 100,000 SQLite rows written per day
- 5 GB SQL storage across the account
- Limits reset at 00:00 UTC. Past a limit, operations of that kind fail with an error.
- Incoming WebSocket messages bill at 20:1 (100 messages count as 5 requests). Outgoing messages and protocol pings are not billed.
- Auto-responses set with `setWebSocketAutoResponse` do not wake the object and add no duration. The docs do not say whether they count toward the 20:1 request ratio.
- Soft limit of 1,000 requests per second per object.
- The docs disagree on per-object storage on Free (a table says 10 GB, the FAQ says 1 GB). The relay stores a few hundred bytes per mailbox, so this does not matter.

## Hibernation

Source: https://developers.cloudflare.com/durable-objects/best-practices/websockets/

- Use `ctx.acceptWebSocket(ws, tags)`. After a short idle period the object leaves memory while the sockets stay connected. The next event re-runs the constructor, so keep it light.
- All in-memory state is lost on eviction. Per-socket state goes in `serializeAttachment` (limit 16,384 bytes, structured-cloneable, lost when the socket closes). Anything else goes in storage.
- In-flight requests, active `alarm()` execution, and `setTimeout`/`setInterval` prevent hibernation. A scheduled future alarm does not prevent hibernation between ticks, so leaving the 90-day clean-up alarm armed still lets the object hibernate.
- Protocol ping frames are answered by the runtime without waking the object. The relay also sets the text auto-response `ping` to `pong`, which does not wake it either.
- Outbound WebSockets from a Durable Object do not hibernate (not used here).

## Claim rate limit: which tool

Checked on 2026-11-18 against https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/.

- The Workers Rate Limiting binding only accepts a `period` of 10 or 60 seconds. The relay needs 10 claims per address per hour, so the binding cannot express it. The docs page also says nothing about the Free plan.
- The relay therefore uses a small SQLite-backed `ClaimLimiter` Durable Object (migration tag `v2`, `new_sqlite_classes`). It is named by a SHA-256 hash of the address, never the address. Storage holds only the times of claims in the last hour, and an alarm deletes it when they are all older than an hour. Rejected claims are not recorded.

## Limits and the single alarm

- Each Mailbox has one alarm, always set to the earliest of: a handshake timeout (10 s to answer the challenge, 15 s for a waiting phone to be paired, 15 s for a data socket to send its token, all closing with 4008), a delayed write of the daily counters, and the clean-up 90 days after the Mac was last seen. Deadlines live in socket attachments and storage, so they survive eviction. With nothing pending, only the clean-up alarm remains.
- Daily counters (messages and UTF-8 bytes of incoming traffic from phone and Mac data sockets) are kept in each paired socket's attachment, which survives hibernation, and are added to the stored totals at most once a minute (the time of the last write is stored with the counts), when a socket closes, and at once when the day is spent. A pair that overspends is ended with close 4029 and the reason "limit <resetsAt>"; nothing is injected into the forwarded stream. The Mac's control socket and waiting phones get a `limit` frame, the Mac once per spent day.
- Bad-handshake counts and blocks are stored in Durable Object storage (one `fails` key, with expiry and an alarm to clear it) so hibernation cannot clear them. Source addresses are read from `CF-Connecting-IP`, normalized (full IPv4, `/64` for IPv6, IPv4-mapped IPv6 normalized to IPv4), and hashed with SHA-256 (`ensemble-relay-ip|<normalized>`, truncated to 16 bytes base64url). Only that hash is kept, in `fails` storage, in socket attachments (`addr`), and as the `ClaimLimiter` Durable Object name. Raw addresses are never logged or stored.

## Live wrangler dev verification (2026-11-18)

- Tested end-to-end with `RelayLiveTests.endToEndThroughWranglerDev` against local `wrangler dev --local` (`workerd`, wrangler 4.164.0): a real `RemoteServer`, `RelayHost`, and relay-only `RemoteClient` paired through `ws://127.0.0.1:8787`, completed a live transcript round trip, and transferred a >5 MiB Mac-to-phone sealed frame byte-for-byte.
- **WebSocket ping/pong on paired sockets:** Verified that `workerd` answers RFC 6455 WebSocket `.ping` control frames with `.pong` on the Mac's adopted data socket (`RemoteServer`'s `NWProtocolWebSocket.Metadata(opcode: .ping)` heartbeat). With a 1 s heartbeat interval (`RemoteServer` drop threshold 4 s) and 1 s client ping interval (10 s per-ping timeout in `RemoteClient`), an idle relayed connection stayed alive across 5.5 s on the same peer ID and carried subsequent sealed requests without dropping.
