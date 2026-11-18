import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const enc = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomID(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

interface Key {
  pair: CryptoKeyPair;
  pub: string;
}

async function newKey(): Promise<Key> {
  const pair = (await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { pair, pub: b64url(raw) };
}

async function sign(key: Key, id: string, nonce: string): Promise<string> {
  const sig = await crypto.subtle.sign("Ed25519", key.pair.privateKey, enc.encode(`ensemble-relay-host|${id}|${nonce}`));
  return b64url(new Uint8Array(sig));
}

/** A WebSocket wrapper that queues messages and close events. */
class Client {
  messages: string[] = [];
  closed: { code: number } | null = null;
  private waiters: Array<() => void> = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (e) => {
      this.messages.push(e.data as string);
      this.wake();
    });
    ws.addEventListener("close", (e) => {
      this.closed = { code: e.code };
      this.wake();
    });
  }

  private wake() {
    const w = this.waiters;
    this.waiters = [];
    for (const f of w) f();
  }

  private async until(cond: () => boolean) {
    const deadline = Date.now() + 5000;
    while (!cond()) {
      if (Date.now() > deadline) throw new Error("timed out");
      await new Promise<void>((r) => {
        this.waiters.push(r);
        setTimeout(r, 100);
      });
    }
  }

  async next(): Promise<any> {
    await this.until(() => this.messages.length > 0);
    return JSON.parse(this.messages.shift()!);
  }

  async closeCode(): Promise<number> {
    await this.until(() => this.closed !== null);
    return this.closed!.code;
  }

  send(obj: unknown) {
    this.ws.send(JSON.stringify(obj));
  }
}

async function connect(id: string, role = "host"): Promise<Client> {
  const res = await SELF.fetch(`https://relay.test/v1/mailbox/${id}/${role}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  return new Client(ws);
}

async function claim(id: string, key: Key, accessKey = b64url(crypto.getRandomValues(new Uint8Array(32)))): Promise<Client> {
  const c = await connect(id);
  const ch = await c.next();
  expect(ch.t).toBe("challenge");
  c.send({ t: "claim", hostKey: key.pub, accessKey, sig: await sign(key, id, ch.nonce) });
  return c;
}

async function auth(id: string, key: Key): Promise<Client> {
  const c = await connect(id);
  const ch = await c.next();
  c.send({ t: "auth", sig: await sign(key, id, ch.nonce) });
  return c;
}

describe("host socket", () => {
  it("rejects unknown routes", async () => {
    expect((await SELF.fetch("https://relay.test/v1/nope")).status).toBe(404);
    const id = randomID();
    expect((await SELF.fetch(`https://relay.test/v1/mailbox/${id}/host`)).status).toBe(426);
    const bad = await SELF.fetch("https://relay.test/v1/mailbox/short/host", { headers: { Upgrade: "websocket" } });
    expect(bad.status).toBe(404);
  });

  it("claims an unclaimed mailbox", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect(await first.next()).toEqual({ t: "ready" });
    first.ws.close(1000);

    const second = await auth(id, key);
    expect(await second.next()).toEqual({ t: "ready" });
  });

  it("refuses a wrong signature", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect((await first.next()).t).toBe("ready");

    const c = await auth(id, await newKey());
    expect(await c.closeCode()).toBe(4001);
  });

  it("refuses a second claim", async () => {
    const id = randomID();
    const first = await claim(id, await newKey());
    expect((await first.next()).t).toBe("ready");

    const other = await claim(id, await newKey());
    expect(await other.closeCode()).toBe(4009);
  });

  it("only one control socket", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect((await first.next()).t).toBe("ready");

    const second = await auth(id, key);
    expect((await second.next()).t).toBe("ready");
    expect(await first.closeCode()).toBe(4009);
  });
});
