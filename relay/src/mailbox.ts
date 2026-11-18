import { DurableObject } from "cloudflare:workers";
import { b64url, Close, encodeControl, fromB64url, MAX_CONTROL_BYTES, parseControl } from "./wire";

/** What each accepted socket remembers across hibernation. Kept small (the platform allows 16,384 bytes). */
interface Attachment {
  role: "host" | "phone" | "data";
  id: string;
  /** The phone's connection id; unused on the host socket. */
  conn?: string;
  /** The challenge nonce, for the host and for a phone that has not yet proved the access key. */
  nonce?: string;
  /** Host: signed in. Phone: proved the access key. */
  authed: boolean;
  /** Phone only: the single-use token the Mac must present on its data socket. Cleared when used. */
  token?: string;
  /** Phone and data: the pair is formed and frames pass through. */
  paired: boolean;
  /** The connecting address, kept for rate limits. */
  ip: string;
}

/** Largest frame a phone may send to the Mac. */
const MAX_PHONE_FRAME = 1024 * 1024;
/** Largest frame the Mac may send to a phone. Under the platform's 32 MiB received-message limit. */
const MAX_MAC_FRAME = 16 * 1024 * 1024;

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
    const role = parts[4];
    const ip = request.headers.get("CF-Connecting-IP") ?? "";
    if (role !== "host" && role !== "phone" && role !== "data") return new Response("not found", { status: 404 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    if (role === "data") {
      // A Mac data socket for one phone. It must present the phone's token as its first frame.
      const conn = parts[5]!;
      this.ctx.acceptWebSocket(server, [`data:${conn}`]);
      server.serializeAttachment({ role, id, conn, authed: false, paired: false, ip } satisfies Attachment);
      return new Response(null, { status: 101, webSocket: client });
    }

    const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
    if (role === "host") {
      this.ctx.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ role, id, nonce, authed: false, paired: false, ip } satisfies Attachment);
    } else {
      const conn = b64url(crypto.getRandomValues(new Uint8Array(16)));
      this.ctx.acceptWebSocket(server, [`phone:${conn}`]);
      server.serializeAttachment({ role, id, conn, nonce, authed: false, paired: false, ip } satisfies Attachment);
    }
    server.send(encodeControl({ t: "challenge", nonce }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return ws.close(Close.protocol, "protocol");
    if (att.role === "phone") return this.phoneMessage(ws, att, message);
    if (att.role === "data") return this.dataMessage(ws, att, message);
    return this.hostMessage(ws, att, message);
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.closePeer(ws, code);
    try {
      ws.close(sendableCode(code), "closed");
    } catch {
      // Already closed.
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.closePeer(ws, 1011);
  }

  private async hostMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    const frame = parseText(message);
    if (!frame) return ws.close(Close.protocol, "protocol");

    if (att.authed) {
      // Later tasks add the frames an authenticated host may send.
      return ws.close(Close.protocol, "protocol");
    }

    if (frame.t === "claim") return this.claim(ws, att, frame.hostKey, frame.accessKey, frame.sig);
    if (frame.t === "auth") return this.auth(ws, att, frame.sig);
    return ws.close(Close.protocol, "protocol");
  }

  /** A phone sends one `access` frame, then nothing until it is paired; after that everything is forwarded. */
  private async phoneMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message) > MAX_PHONE_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      const data = this.pairedSocket(`data:${att.conn}`);
      if (!data) return ws.close(Close.macOffline, "mac offline");
      return data.send(message);
    }
    const frame = att.authed ? null : parseText(message);
    if (!frame || frame.t !== "access") return ws.close(Close.protocol, "protocol");

    const accessKey = await this.ctx.storage.get<string>("accessKey");
    if (!accessKey) return ws.close(Close.noMailbox, "no such mailbox");
    if (!(await verifyPhone(accessKey, frame.proof, att.id, att.nonce!))) {
      return ws.close(Close.unauthorized, "unauthorized");
    }
    // The proof check awaited. Re-read the attachment so a repeated `access` frame cannot mint a second token.
    const now = ws.deserializeAttachment() as Attachment | null;
    if (!now || ws.readyState !== WebSocket.READY_STATE_OPEN) return;
    // A second `access` frame, sent before the first finished, is a frame before paired.
    if (now.authed) return ws.close(Close.protocol, "protocol");

    const host = this.ctx
      .getWebSockets("host")
      .find((h) => h.readyState === WebSocket.READY_STATE_OPEN && (h.deserializeAttachment() as Attachment | null)?.authed);
    if (!host) {
      ws.send(encodeControl({ t: "error", code: "macOffline", message: "The Mac is offline." }));
      return ws.close(Close.macOffline, "mac offline");
    }
    const token = b64url(crypto.getRandomValues(new Uint8Array(32)));
    ws.serializeAttachment({ ...now, authed: true, token, nonce: undefined } satisfies Attachment);
    ws.send(encodeControl({ t: "waiting" }));
    host.send(encodeControl({ t: "phone", conn: att.conn!, token }));
  }

  /** A data socket sends one `data` frame with the phone's token, then frames pass to that phone. */
  private async dataMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message) > MAX_MAC_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      const phone = this.pairedSocket(`phone:${att.conn}`);
      if (!phone) return ws.close(Close.protocol, "no phone");
      return phone.send(message);
    }
    const frame = parseText(message);
    if (!frame || frame.t !== "data") return ws.close(Close.protocol, "protocol");

    // No await between the token check and consuming it, so a token pairs at most once.
    const phone = this.ctx.getWebSockets(`phone:${att.conn}`)[0];
    const pAtt = phone?.deserializeAttachment() as Attachment | null | undefined;
    if (!phone || !pAtt || pAtt.paired || !pAtt.authed || !pAtt.token || !sameString(pAtt.token, frame.token)) {
      return ws.close(Close.unauthorized, "unauthorized");
    }
    phone.serializeAttachment({ ...pAtt, paired: true, token: undefined } satisfies Attachment);
    ws.serializeAttachment({ ...att, authed: true, paired: true } satisfies Attachment);
    phone.send(encodeControl({ t: "paired" }));
  }

  /** The socket with this tag that has completed pairing, if any. Unpaired sockets are never a peer. */
  private pairedSocket(tag: string): WebSocket | undefined {
    return this.ctx.getWebSockets(tag).find((w) => (w.deserializeAttachment() as Attachment | null)?.paired);
  }

  /**
   * Closes the other half of a pair. Only a paired socket has a peer: a phone that is still waiting, or a data
   * socket that never proved the token, closing or failing affects nobody else.
   */
  private closePeer(ws: WebSocket, code: number) {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att || !att.paired || (att.role !== "phone" && att.role !== "data")) return;
    const peerTag = att.role === "phone" ? `data:${att.conn}` : `phone:${att.conn}`;
    const peer = this.pairedSocket(peerTag);
    if (!peer || peer === ws) return;
    try {
      peer.close(sendableCode(code), "peer closed");
    } catch {
      // Already closed.
    }
  }

  private closeBoth(ws: WebSocket, att: Attachment, code: number, reason: string) {
    this.closePeer(ws, code);
    ws.close(code, reason);
  }

  private async claim(ws: WebSocket, att: Attachment, hostKey: string, accessKey: string, sig: string) {
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return ws.close(Close.unauthorized, "unauthorized");
    // The signature check awaited, so look again before writing: the first claim wins.
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    await this.ctx.storage.put({ hostKey, accessKey, lastUsed: Date.now() });
    this.becomeHost(ws, att);
  }

  private async auth(ws: WebSocket, att: Attachment, sig: string) {
    const hostKey = await this.ctx.storage.get<string>("hostKey");
    if (!hostKey) return ws.close(Close.noMailbox, "no such mailbox");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return ws.close(Close.unauthorized, "unauthorized");
    await this.ctx.storage.put("lastUsed", Date.now());
    this.becomeHost(ws, att);
  }

  /** Marks this socket as the control socket and closes any older one. */
  private becomeHost(ws: WebSocket, att: Attachment) {
    for (const other of this.ctx.getWebSockets("host")) {
      if (other === ws) continue;
      const otherAtt = other.deserializeAttachment() as Attachment | null;
      if (otherAtt?.authed) {
        // Mark it signed out first: it can linger in getWebSockets until its close handshake ends.
        other.serializeAttachment({ ...otherAtt, authed: false } satisfies Attachment);
        other.close(Close.taken, "replaced");
      }
    }
    ws.serializeAttachment({ ...att, authed: true, nonce: undefined } satisfies Attachment);
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

async function verifyPhone(accessKeyB64: string, proofB64: string, id: string, nonce: string): Promise<boolean> {
  const keyBytes = fromB64url(accessKeyB64);
  const mac = fromB64url(proofB64);
  if (!keyBytes || !mac) return false;
  try {
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    return await crypto.subtle.verify("HMAC", key, mac, enc.encode(`ensemble-relay-phone|${id}|${nonce}`));
  } catch {
    return false;
  }
}

/** Parses a control frame. Binary frames and oversized text are rejected before any decoding or encoding. */
function parseText(message: string | ArrayBuffer) {
  // A string's UTF-16 length never exceeds its UTF-8 byte length, so this bound needs no encode.
  if (typeof message !== "string" || message.length > MAX_CONTROL_BYTES) return null;
  return parseControl(message);
}

/** Size in bytes. For text this encodes only when the length alone cannot decide. */
function byteLength(message: string | ArrayBuffer): number {
  if (typeof message !== "string") return message.byteLength;
  if (message.length > MAX_MAC_FRAME) return message.length; // already over every cap
  return enc.encode(message).length;
}

function sameString(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** Close codes 1005, 1006 and 1015 cannot be sent; map anything outside the sendable ranges to 1000. */
function sendableCode(code: number): number {
  return code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000;
}
