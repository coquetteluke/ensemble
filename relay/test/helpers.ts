import { SELF } from "cloudflare:test";
import { expect } from "vitest";

export const enc = new TextEncoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export function randomID(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export interface Key {
  pair: CryptoKeyPair;
  pub: string;
}

export async function newKey(): Promise<Key> {
  const pair = (await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { pair, pub: b64url(raw) };
}

export async function sign(key: Key, id: string, nonce: string): Promise<string> {
  const sig = await crypto.subtle.sign("Ed25519", key.pair.privateKey, enc.encode(`ensemble-relay-host|${id}|${nonce}`));
  return b64url(new Uint8Array(sig));
}

/** The phone proof: HMAC-SHA256 under the access key over the phone label, the id and the nonce. */
export async function proof(accessKey: string, id: string, nonce: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", fromB64(accessKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`ensemble-relay-phone|${id}|${nonce}`));
  return b64url(new Uint8Array(mac));
}

/** A WebSocket wrapper that queues messages and close events. */
export class Client {
  messages: Array<string | ArrayBuffer> = [];
  closed: { code: number } | null = null;
  private waiters: Array<() => void> = [];

  constructor(readonly ws: WebSocket) {
    ws.binaryType = "arraybuffer";
    ws.addEventListener("message", (e) => {
      this.messages.push(e.data as string | ArrayBuffer);
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

  private async until(cond: () => boolean, ms = 5000) {
    const deadline = Date.now() + ms;
    while (!cond()) {
      if (Date.now() > deadline) throw new Error("timed out");
      await new Promise<void>((r) => {
        this.waiters.push(r);
        setTimeout(r, 100);
      });
    }
  }

  async nextRaw(): Promise<string | ArrayBuffer> {
    await this.until(() => this.messages.length > 0);
    return this.messages.shift()!;
  }

  async next(): Promise<any> {
    return JSON.parse((await this.nextRaw()) as string);
  }

  async closeCode(): Promise<number> {
    await this.until(() => this.closed !== null);
    return this.closed!.code;
  }

  /** Waits long enough for events to land, then reports that nothing arrived and the socket is still open. */
  async quiet(ms = 200): Promise<boolean> {
    await new Promise((r) => setTimeout(r, ms));
    return this.messages.length === 0 && this.closed === null;
  }

  send(obj: unknown) {
    this.ws.send(JSON.stringify(obj));
  }
}

export async function connect(id: string, role = "host"): Promise<Client> {
  const res = await SELF.fetch(`https://relay.test/v1/mailbox/${id}/${role}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  return new Client(ws);
}

export async function claim(
  id: string,
  key: Key,
  accessKey = b64url(crypto.getRandomValues(new Uint8Array(32))),
): Promise<Client> {
  const c = await connect(id);
  const ch = await c.next();
  expect(ch.t).toBe("challenge");
  c.send({ t: "claim", hostKey: key.pub, accessKey, sig: await sign(key, id, ch.nonce) });
  return c;
}

export async function auth(id: string, key: Key): Promise<Client> {
  const c = await connect(id);
  const ch = await c.next();
  c.send({ t: "auth", sig: await sign(key, id, ch.nonce) });
  return c;
}
