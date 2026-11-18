import { DurableObject } from "cloudflare:workers";
import { b64url, Close, encodeControl, fromB64url, MAX_CONTROL_BYTES, parseControl } from "./wire";

/** What each accepted socket remembers across hibernation. Kept small (the platform allows 2 KiB). */
interface Attachment {
  role: "host";
  id: string;
  nonce: string;
  authed: boolean;
}

const enc = new TextEncoder();

/**
 * One mailbox per paired Mac. Storage keys:
 * - hostKey: the Mac's Ed25519 public key (b64url), set by the first claim
 * - accessKey: the key phones prove knowledge of (b64url)
 * - lastUsed: unix ms of the last host sign-in
 */
export class Mailbox extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const parts = new URL(request.url).pathname.split("/");
    const id = parts[3]!;
    if (parts[4] !== "host") return new Response("not found", { status: 404 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, ["host"]);
    const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
    server.serializeAttachment({ role: "host", id, nonce, authed: false } satisfies Attachment);
    server.send(encodeControl({ t: "challenge", nonce }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return ws.close(Close.protocol, "protocol");
    if (typeof message !== "string" || enc.encode(message).length > MAX_CONTROL_BYTES) {
      return ws.close(Close.protocol, "protocol");
    }
    const frame = parseControl(message);
    if (!frame) return ws.close(Close.protocol, "protocol");

    if (att.authed) {
      // Later tasks add the frames an authenticated host may send.
      return ws.close(Close.protocol, "protocol");
    }

    if (frame.t === "claim") return this.claim(ws, att, frame.hostKey, frame.accessKey, frame.sig);
    if (frame.t === "auth") return this.auth(ws, att, frame.sig);
    return ws.close(Close.protocol, "protocol");
  }

  private async claim(ws: WebSocket, att: Attachment, hostKey: string, accessKey: string, sig: string) {
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce))) return ws.close(Close.unauthorized, "unauthorized");
    // The signature check awaited, so look again before writing: the first claim wins.
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    await this.ctx.storage.put({ hostKey, accessKey, lastUsed: Date.now() });
    this.becomeHost(ws, att);
  }

  private async auth(ws: WebSocket, att: Attachment, sig: string) {
    const hostKey = await this.ctx.storage.get<string>("hostKey");
    if (!hostKey) return ws.close(Close.noMailbox, "no such mailbox");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce))) return ws.close(Close.unauthorized, "unauthorized");
    await this.ctx.storage.put("lastUsed", Date.now());
    this.becomeHost(ws, att);
  }

  /** Marks this socket as the control socket and closes any older one. */
  private becomeHost(ws: WebSocket, att: Attachment) {
    for (const other of this.ctx.getWebSockets("host")) {
      if (other === ws) continue;
      if ((other.deserializeAttachment() as Attachment | null)?.authed) other.close(Close.taken, "replaced");
    }
    ws.serializeAttachment({ ...att, authed: true } satisfies Attachment);
    ws.send(encodeControl({ t: "ready" }));
  }
}

async function verifyHost(hostKeyB64: string, sigB64: string, id: string, nonce: string): Promise<boolean> {
  const keyBytes = fromB64url(hostKeyB64);
  const sig = fromB64url(sigB64);
  if (!keyBytes || !sig) return false;
  try {
    const key = await crypto.subtle.importKey("raw", keyBytes, "Ed25519", false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, sig, enc.encode(`ensemble-relay-host|${id}|${nonce}`));
  } catch {
    return false;
  }
}
