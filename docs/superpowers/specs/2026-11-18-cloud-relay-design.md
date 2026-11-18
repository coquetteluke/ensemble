# Ensemble Cloud Relay: design

Status: approved by Luke (2026-11-18).

## Why

Today the iPhone reaches the Mac only on the same Wi-Fi or over Tailscale. That needs setup most people will never do. Luke wants the remote to work for everyone with no setup: scan the QR code once, then it works on any Wi-Fi or cellular network. It must be end-to-end encrypted, so whoever runs the relay (Luke, or anyone self-hosting) cannot read anything, not even their own messages. Ensemble may go public, and other developers may want to build on it, so the relay should be open source and easy to run yourself.

## Goals

- **It just works.** After one QR scan the phone reaches the Mac from anywhere, with no Tailscale, port forwarding or router settings. It is on by default when Remote is on.
- **End-to-end encrypted.** The relay only ever handles sealed bytes. It cannot read, change, replay or reorder messages without both sides noticing.
- **Forward secrecy.** Traffic recorded at the relay stays unreadable even if the pairing code leaks later.
- **Cheap and quiet when idle.** A Mac with no phone connected costs close to nothing.
- **Self-hostable.** The relay lives in this repo with a short guide to deploying your own. The app has a relay address setting.

## Non-goals (for now)

- Direct phone-to-Mac connections with NAT hole punching. A later upgrade could add them on top of this relay.
- Holding messages for a phone that is offline. Phone alerts already go through ntfy.
- Accounts, sign-up, or sharing a Mac with other people.
- Android or web clients.

## Anti-goals (failure even if it works)

- The relay, or anyone operating it, can read message content or the pairing code.
- Ensemble's relay logs or stores IP addresses, mailbox IDs or traffic records.
- Strangers can use the relay as a general-purpose tunnel, or run up Luke's Cloudflare bill.
- One person's mailbox can be knocked offline by someone who doesn't hold its keys.

## Constraints

- A Claude subscription serves only its owner. The relay only connects a Mac to phones holding that Mac's pairing code. Nothing here shares sessions between people.
- No third-party Swift packages. CryptoKit and Network.framework cover the Swift side. The relay itself is a TypeScript Cloudflare Worker, so npm dev tools (wrangler, vitest, `@cloudflare/vitest-pool-workers`) are fine inside `relay/` only.
- No secrets in the repo. The Cloudflare account ID and API tokens stay out of `wrangler.toml`: wrangler uses the logged-in account.
- The default relay address `wss://relay.coquettemc.com` will be in the public code. Luke chose coquettemc.com for now. Moving to an Ensemble domain later is a one-line change plus a redeploy.
- Deploying to Luke's Cloudflare account is an outward action. Luke signs in once with `npx wrangler login` in his browser, and each deploy is confirmed with him first.
- No em dashes anywhere (house rule).

## Approaches considered

1. **Relay on Luke's mc server.** Docker behind the existing Cloudflare tunnel. Full control, but it uses mc's home connection and depends on mc's uptime.
2. **The same relay on Cloudflare Workers with Durable Objects. Chosen by Luke.** It runs worldwide, mc's connection and uptime don't matter, and it costs nothing when idle thanks to WebSocket hibernation. The trade-offs: it's tied to a Cloudflare account and its limits, and self-hosters need their own Cloudflare account (free).
3. **Direct connections first, relay as fallback** (how Tailscale works inside). Less relay traffic, but far more complex. It stays a possible later upgrade.

iCloud (CloudKit) was ruled out: it needs a paid Apple developer account, and it is too slow for live agent output.

## How it works

### Pieces

- **Worker** (`relay/src/index.ts`): accepts WebSocket upgrades at `/v1/mailbox/<mailboxID>/<role>` and routes them to the Durable Object for that mailbox. It rejects anything else.
- **Mailbox Durable Object** (`relay/src/mailbox.ts`): one per paired Mac, SQLite-backed (allowed on the Workers free plan). It uses the WebSocket Hibernation API (`ctx.acceptWebSocket`, tags, `serializeAttachment`, and `setWebSocketAutoResponse` for ping and pong). Hibernated sockets cost nothing.
- **Mac**: a relay host client alongside the existing `RemoteServer`.
- **iPhone**: a relay dial path alongside the existing direct hosts.

### Mailbox and host identity

- **Mailbox ID:** 32 random bytes, base64url. The Mac creates it with its pairing code and stores it in the keychain next to the token. It goes in the QR code. It is an address, not a secret: it appears in the request path, which Cloudflare can see.
- **Relay access key:** `HKDF(token, "ensemble-relay-access")`. It is one-way, so it never reveals the token. The Mac registers it with the mailbox. A phone must prove it knows the key (an HMAC over a fresh relay challenge) before the relay wakes the Mac. Strangers who only know the mailbox ID are turned away at the relay. Regenerating the pairing code makes a new token, so a new access key and a new mailbox ID, and old phones can no longer reach the mailbox at all.
- **Host key:** Curve25519 signing (Ed25519, CryptoKit). The Mac makes one per mailbox and keeps it in the keychain.
- **Claiming the mailbox:** the first host connection claims it by registering the host public key. The Mac does this as soon as the mailbox is created, before the QR code is shown, so nobody can claim it first.
- **Proving ownership:** every later host connection proves ownership by signing a fresh challenge from the Durable Object. Only the Mac can be the host.
- **What the relay stores:** the host public key, the relay access key, the per-mailbox daily counters (below), and a last-used date. Nothing else. An alarm deletes mailboxes unused for 90 days.
- **A missing mailbox:** if it was deleted by that alarm or by a redeploy, the Mac claims the same ID again with the same host key, silently. If the ID is held by a different host key, which should never happen, the Mac makes a new mailbox and shows "Scan the new pairing code".

### Connections

1. **Control socket:** the Mac keeps one host connection to its mailbox. It is idle and hibernated almost all the time.
2. **A phone arrives:** it connects to the mailbox in the phone role. The Durable Object gives it a short random connection ID and sends the Mac a small "phone waiting" notice on the control socket.
3. **Data socket:** the Mac opens a new data connection for that ID. The Durable Object then forwards binary messages between that phone socket and that data socket, untouched. Socket tags and attachments carry the pairing, so forwarding survives hibernation.
4. **The Mac side:** each data socket is handed to the existing `RemoteServer` connection handling as if it were a direct inbound connection. The existing handshake, encryption, device limits and message handling stay as they are. `RemoteServer` needs a way to accept a connection the Mac dialed out instead of one its listener accepted.
5. **Closing:** when either socket of a pair closes, the Durable Object closes the other.

### End-to-end encryption: protocol 4

The current protocol (3) already gives:
- A mutual HMAC challenge-response, so the token never travels.
- ChaChaPoly per direction, with counters as nonces, so changed, dropped, replayed or reordered frames all fail.

For the relay, add forward secrecy. This is protocol version 4, and it applies to direct connections too:
- The `challenge` carries the Mac's fresh ephemeral X25519 public key. The `hello` carries the phone's.
- The HMAC proofs cover both ephemeral keys, so a relay that swaps a key fails the proof. It cannot forge an HMAC without the token.
- Key derivation mixes the X25519 shared secret into the input key material, together with the token.
- The ephemeral private keys are thrown away after the handshake.

Channel binding today uses the host and port the phone dialed. For relay connections, the dialed identity is `relay:<relay host>/<mailboxID>`, so keys made for one mailbox never open another's frames.

Minimum version becomes 4 on both sides. The Mac and phone apps are updated together, and nothing is public yet, so there is no compatibility burden.

### Pairing code

`RemotePairing` gains an optional `relay` field `{ url, mailbox }`. The QR code and copied pairing code carry it. Codes without it still pair direct only.

A pairing code may have no direct hosts when it has a relay. Today a code with no hosts is rejected, and the Mac shows no QR code without Tailscale or the local network toggle. Both change: with the relay on, the QR code always shows.

### Keeping phones paired when the relay moves

- Whenever a phone connects, the Mac sends the current relay details (URL and mailbox ID) inside the encrypted channel, and the phone saves them. This is a new message in `RemoteProtocol.swift`.
- Changing the relay address setting, or moving the default off coquettemc.com, reaches every phone that connects at least once through either the old relay or a direct path. No new scan is needed.
- The phone keeps the previous relay details as a fallback until it has connected once through the new ones.
- The Mac stays registered on the old relay until all its paired phones have learned the new one, or for 30 days, whichever comes first.

### Phone connection order

- The phone tries its direct hosts (Tailscale, and the local network when the Mac allows it) and the relay at the same time. It prefers a direct connection that completes within about 300 ms of the relay one, and otherwise uses the relay.
- The local network listener stays off by default, as today. So for someone with no setup, home connections also go through the relay. That is still end to end encrypted, and the traffic is small.

### Abuse and limits

The relay enforces:
- At most 8 phone sockets per mailbox (the Mac's device limit), and at most 3 waiting for a data socket.
- A phone socket closes if no data socket pairs with it within 15 seconds.
- 1 MiB per message, the same as the Mac's limit today.
- A per-mailbox message rate cap, plus a daily budget per mailbox: about 40,000 incoming messages and 200 MB a day.
  - That covers more than 2 hours of live streaming, and it means one mailbox can use at most about 2% of the free plan's daily requests.
  - The counters live in memory and are written to storage at most once a minute, so they stay well inside the free plan's row-write allowance.
  - When a budget runs out, both sides get a "daily relay limit reached" message, which the apps show.
- Mailbox claims limited per client IP, using the Workers rate limiting binding or a small counter object, so nobody can spam mailboxes.
- Every message on the control socket is checked against a tiny fixed schema. Anything else closes the socket.

The relay checks the access proof itself. On top of that, handshake failures inside the encryption, which the relay cannot see, are handled this way:
- The Mac reports "bad handshake from connection ID" on its control socket.
- The Durable Object keeps an in-memory, per-mailbox count by client IP and refuses that IP for 15 minutes after 5 failures.
- Nothing is written to storage. The Mac never learns phone IPs.

### Privacy

- Worker observability and logging are off, and the relay code never logs IDs or IPs.
- Cloudflare can still see connection metadata: IP addresses, timing and sizes. No relay can avoid that. The docs say so plainly.
- The Mac's name, session titles and everything else stay inside the encrypted channel. They are only in the QR code, which never touches the relay.

### Costs (Cloudflare, checked 2026-11-18)

- **Free plan:** 100,000 requests a day. Incoming WebSocket messages count at 20 to 1, so about 2 million messages a day. Outgoing messages and protocol pings are free, and hibernated sockets cost no duration.
- **A rough estimate:** an active session streams maybe 5 messages a second while someone watches. That is about 900 requests an hour of watching, so the free plan covers on the order of 100 watched hours a day across everyone.
- **When the free limit is used up:** relay operations fail until midnight UTC, and phones fall back to direct connections where they can.
- **One mailbox's share:** with the per-mailbox budget, a single mailbox can use at most about 2% of the free plan's day, so one heavy or abusive user cannot take the relay down for everyone.
- **The Workers Paid plan ($5 a month):** removes the daily cap. It includes 1 million requests a month, then $0.15 per million. Luke decides if and when to switch. Nothing in the design depends on it.

### Mac settings

Under Remote:
- **Connect from anywhere (end-to-end encrypted).** On by default.
- **Relay address.** Under an Advanced disclosure. Default `wss://relay.coquettemc.com`, editable for self-hosters.
- The existing local network toggle stays as it is.

## Repo layout

- `relay/`: `wrangler.toml` (no account ID; the custom domain `relay.coquettemc.com`), `package.json`, `src/index.ts`, `src/mailbox.ts`, `test/`, and a `README.md` on deploying your own relay.
- Swift:
  - The relay host client, and a relay-aware dialer on the phone, as new files in `Remote/`.
  - Protocol 4 changes in `RemoteAuth.swift`, `RemoteChannel.swift` and `RemoteProtocol.swift`.
  - The `RemotePairing.relay` field.
  - The connection hand-off in `RemoteServer.swift`, and the dial logic in `RemoteClient.swift`.
  - The Mac settings UI in `Apps/Mac/Remote/` and `Apps/Mac/Settings/`.
- Docs: a "Cloud relay" section in `docs/DESIGN.md`, a privacy note, and `docs/reference/relay-notes.md` for Cloudflare specifics.

## Testing

- **Relay** (vitest with `@cloudflare/vitest-pool-workers`, local and free):
  - claiming a mailbox and refusing a second claim
  - host challenge signing, with a wrong signature refused
  - phone waiting, then pairing, then forwarding both ways, byte for byte
  - forwarding after hibernation
  - limits and timeouts, and the per-IP backoff after failures
  - unknown routes refused
- **Swift:**
  - Protocol 4 handshake unit tests: a swapped ephemeral key fails, recorded frames don't open with only the token, and old versions are refused.
  - Loopback tests through a small fake relay written with Network.framework in the test target.
  - An opt-in live test (`ENSEMBLE_LIVE_TESTS=1`) against `wrangler dev`.
- **By hand:** the iPhone Duo on cellular with Wi-Fi off, after Luke approves the first deploy.

## Left to the builder

- Exact wire format of the control messages (small JSON is fine) and route names.
- Rate limit numbers beyond those above.
- Forwarding text frames as well as binary ones, unchanged.
- Keeping the Mac's per-address handshake limiter from treating all relayed phones as one address: key it by relay connection ID.
- Keeping the per-IP failure counts across hibernation, if that matters in practice.
- How `RemoteServer` takes a dialed-out connection (protocol, closure, or a connection wrapper).
- Reconnect backoff for the control socket.
- How the Mac app surfaces relay state: "Connected through relay", "Relay unreachable", "Daily relay limit reached".
