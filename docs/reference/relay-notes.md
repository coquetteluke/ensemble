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
- Alarms, in-flight requests and `setTimeout`/`setInterval` prevent hibernation.
- Protocol ping frames are answered by the runtime without waking the object. The relay also sets the text auto-response `ping` to `pong`, which does not wake it either.
- Outbound WebSockets from a Durable Object do not hibernate (not used here).

## Claim rate limit: which tool

Checked on 2026-11-18 against https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/.

- The Workers Rate Limiting binding only accepts a `period` of 10 or 60 seconds. The relay needs 10 claims per address per hour, so the binding cannot express it. The docs page also says nothing about the Free plan.
- The relay therefore uses a small SQLite-backed `ClaimLimiter` Durable Object (migration tag `v2`, `new_sqlite_classes`). It is named by a SHA-256 hash of the address, never the address. Storage holds only the times of claims in the last hour, and an alarm deletes it when they are all older than an hour. Rejected claims are not recorded.

## Limits and the single alarm

- Each Mailbox has one alarm, always set to the earliest of: a handshake timeout (10 s to answer the challenge, 15 s for a waiting phone to be paired, 15 s for a data socket to send its token, all closing with 4008), a delayed write of the daily counters, and the clean-up 90 days after the Mac was last seen. Deadlines live in socket attachments and storage, so they survive eviction. With nothing pending, only the clean-up alarm remains.
- Daily counters (messages and bytes, both directions of incoming traffic) are kept in memory and written at most once a minute, plus one write at the moment the day is spent so that a reconnect or eviction cannot reset it. Text frames are charged by UTF-16 length.
- Bad-handshake counts by address are memory only and are lost when the object is evicted. Addresses are read from `CF-Connecting-IP`, are never logged, and are never written to storage; a phone's address stays in its socket attachment only while that socket is open.
