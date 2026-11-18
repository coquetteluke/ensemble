# Ensemble relay

A Cloudflare Worker with one Durable Object per paired Mac (a mailbox). It lets the iPhone remote reach the Mac from any network. It only carries bytes the two sides have sealed; it cannot read them.

## Run the tests

```bash
cd relay
npm install
npm run types   # regenerates worker-configuration.d.ts (not committed)
npx vitest run
```

Run `npm run types` again whenever `wrangler.toml` changes (for example a new Durable Object binding), and before running the tests or deploying, or the `Env` type will be out of date.

## Deploy your own relay

You need a free Cloudflare account. Nothing here deploys for you.

1. `cd relay && npm install`
2. `npx wrangler login`
3. In `wrangler.toml`, change the `routes` pattern to a hostname on a zone in your account (the default is `relay.coquettemc.com`), or remove `routes` to use a `workers.dev` address.
4. `npx wrangler deploy`
5. In Ensemble, set the relay address to `wss://<your host>`.

The relay runs on the Workers free plan (SQLite-backed Durable Objects). Logging is off. See `docs/reference/relay-notes.md` for the platform limits it was designed around.
