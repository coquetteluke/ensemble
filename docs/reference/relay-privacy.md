# Cloud relay privacy

Ensemble's cloud relay connects your iPhone and Mac across any network without exposing your session contents. This note states plainly what Cloudflare and the relay can see, what the relay stores, and what nobody can read.

## What Cloudflare can see

Because the relay runs on Cloudflare Workers and Durable Objects, Cloudflare's network handles the TLS connection and sees connection metadata that no hosted relay can hide:

- **IP addresses** of the connecting Mac and iPhone.
- **Connection timing and duration** (when a Mac signs in, when a phone connects, and how long sockets stay open).
- **Message counts and frame sizes** (the byte length of each sealed WebSocket frame).
- **Mailbox IDs in request paths** (`/v1/mailbox/<id>/host`, `/phone`, `/data/<conn>`). A mailbox ID is a random 32-byte routing address, not a secret.

## What the relay stores

Worker observability is disabled (`observability.enabled = false` in `relay/wrangler.toml`), and the Worker code never writes mailbox IDs, IP addresses, or frame payloads to logs.

Each paired Mac has one SQLite-backed `Mailbox` Durable Object storing only:

- **`hostKey`:** the Mac's Ed25519 public key (base64url), used to verify that only your Mac can attach as the host.
- **`accessKey`:** a one-way HKDF-SHA256 key derived from the pairing token (`salt: "ensemble-relay"`, `info: "ensemble-relay-access"`). Phones prove knowledge of it via HMAC-SHA256 before the relay wakes the Mac. It cannot be reversed to recover the pairing token.
- **`budget`:** per-mailbox daily incoming message and byte counters for the current UTC day (along with flush and notification bookkeeping) to enforce the 40,000-message / 200 MiB daily cap.
- **`lastUsed`:** Unix millisecond timestamp of the last host sign-in or sign-out. An alarm deletes all storage for the mailbox after 90 days idle.
- **`fails`:** temporary bad-handshake counters and 15-minute block expiries reported by the Mac (`badHandshake`), keyed only by a truncated 16-byte SHA-256 hash (`ensemble-relay-ip|<normalized>`) of the normalized client IP (full IPv4 address, or `/64` prefix for IPv6, with IPv4-mapped IPv6 normalized to IPv4). Entries are deleted by alarm when they expire.

A second small SQLite-backed `ClaimLimiter` Durable Object throttles new mailbox claims to 10 per normalized IP per hour. Each `ClaimLimiter` instance is named by that same SHA-256 address hash, stores only claim timestamps from the past hour (`claims`), and deletes itself by alarm once all entries are older than an hour.

Raw IP addresses are never written to Durable Object storage, socket attachments, or logs, and the Mac never learns phone IP addresses.

## What nobody can read

Neither Cloudflare nor the relay operator (including Luke on the default relay, or anyone running a self-hosted relay) can read, alter, replay, or reorder your traffic:

- **All content stays end-to-end encrypted:** transcripts, chat messages, prompts, tool calls, diffs, session titles, project paths, room state, permission replies, and usage data travel only inside ChaChaPoly-sealed binary frames (protocol version 4).
- **The pairing token (pairing code) never touches the relay:** it is shared once through the QR code and never sent over the network. Both sides prove knowledge of it with HMAC-SHA256 over fresh nonces and ephemeral keys.
- **The Mac's name stays private:** it lives in the QR code and inside the encrypted `welcome` frame, never in relay control frames or storage.
- **Forward secrecy:** every connection runs a fresh X25519 ephemeral key exchange whose shared secret is mixed with the pairing token via HKDF-SHA256 (`token UTF-8 || sharedSecret`), and both ephemeral private keys are discarded immediately after the handshake. Traffic recorded at the relay remains unreadable even if the pairing code leaks later.

## Self-hosting

If you prefer not to route metadata through the default relay (`wss://relay.coquettemc.com`), you can deploy the same Worker on your own free Cloudflare account and point Ensemble's **Advanced -> Relay address** setting at it. See `relay/README.md`.
