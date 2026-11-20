# Ensemble relay

A Cloudflare Worker with SQLite-backed Durable Objects (`Mailbox` per paired Mac, plus `ClaimLimiter` for claim throttling). It lets the iPhone remote reach your Mac from any network while carrying only end-to-end encrypted bytes that the relay cannot read.

## Run tests and regenerate types

```bash
cd relay
npm install
npm run types   # regenerates worker-configuration.d.ts (gitignored)
npm test        # runs the Vitest / workerd suite
```

Run `npm run types` again whenever `wrangler.toml` changes (for example a new Durable Object binding), and before running tests or deploying, so the generated `Env` types stay current.

To run the Swift end-to-end test against a local `wrangler dev` instance:

```bash
cd Packages/EnsembleKit
ENSEMBLE_LIVE_RELAY=1 ENSEMBLE_RELAY_URL=ws://127.0.0.1:8787 swift test --filter RelayLiveTests
```

If nothing is listening on port 8787 yet, the test starts `npx wrangler dev --local --port 8787` automatically and stops its process group when done.

## Deploy your own relay

You only need a free Cloudflare account (Workers Free plan with SQLite-backed Durable Objects). Nothing here deploys for you automatically.

1. Install dependencies and sign in to your Cloudflare account:
   ```bash
   cd relay
   npm install
   npx wrangler login
   ```
2. Configure your domain in `relay/wrangler.toml`:
   - Change `routes = [{ pattern = "relay.coquettemc.com", custom_domain = true }]` to a hostname on a zone in your Cloudflare account, or remove `routes` to use your `workers.dev` subdomain.
   - Do **not** add or commit `account_id` in `wrangler.toml`; Wrangler uses the account from `wrangler login`.
3. Regenerate types and verify tests pass:
   ```bash
   npm run types
   npm test
   ```
4. Deploy the Worker:
   ```bash
   npx wrangler deploy
   ```
5. Verify the deployment responds with `404` on an unknown route (and `426` on a non-WebSocket request to a valid mailbox route):
   ```bash
   curl -i https://<your-host>/v1/nope
   ```
6. Point Ensemble at your relay:
   - On your Mac, open Ensemble's **Settings -> Remote**, expand **Advanced**, and set **Relay address** to `wss://<your-host>`.
   - Already-paired phones learn the new relay address over the encrypted channel the next time they connect; the Mac keeps the previous relay host running for 30 days so no QR rescan is needed.

## Privacy and platform limits

- Worker observability is off (`observability.enabled = false`), and the relay never logs mailbox IDs, IP addresses, or frames.
- See `docs/reference/relay-privacy.md` for what Cloudflare can and cannot see, and `docs/reference/relay-notes.md` for Workers Free plan limits and hibernation details.
