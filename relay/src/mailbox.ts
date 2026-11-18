import { DurableObject } from "cloudflare:workers";
import {
  BLOCK_MS,
  BUDGET_FLUSH_MS,
  CHALLENGE_TIMEOUT_MS,
  DAILY_BYTES,
  DAILY_MESSAGES,
  FAILURES_BEFORE_BLOCK,
  IDLE_DELETE_MS,
  MAX_PHONES,
  MAX_WAITING,
  PAIR_TIMEOUT_MS,
} from "./limits";
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
  /** The connecting address, kept only for this socket's lifetime so the Mac's badHandshake can be tied to it. */
  ip: string;
  /** Unix ms by which this socket must finish what it is waiting for, or it is closed with 4008. */
  deadline?: number;
}

/** Incoming traffic for one UTC day. */
interface Budget {
  day: number;
  messages: number;
  bytes: number;
}

const DAY_MS = 86_400_000;

function today(): number {
  return Math.floor(Date.now() / DAY_MS);
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
 * - lastUsed: unix ms of the last host sign-in or sign-out
 * - budget: the day's incoming message and byte counts, written at most once a minute
 *
 * The one alarm serves three deadlines and is always set to the earliest: pending handshake timeouts, a delayed
 * budget write, and the 90-day clean-up. With nothing pending, only the clean-up alarm remains.
 */
export class Mailbox extends DurableObject<Env> {
  /** Today's counts. Memory only between writes; see noteTraffic. Public so tests can set it. */
  budget: Budget = { day: today(), messages: 0, bytes: 0 };
  /** How many times the budget has been written to storage. Public so tests can count the writes. */
  budgetWrites = 0;
  private budgetLoading: Promise<void> | null = null;
  private budgetDirty = false;
  private lastFlush = 0;
  /** Bad handshakes the Mac reported, by source address. Memory only, so it is gone on eviction. */
  private failures = new Map<string, { count: number; since: number; blockedUntil: number }>();
  /** The last few phones' addresses by connection id, so a report that arrives after the phone left still counts. */
  private recentPhones = new Map<string, string>();

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
    const deadline = Date.now() + CHALLENGE_TIMEOUT_MS;

    if (role === "phone" && this.isBlocked(ip)) {
      // No challenge and no notice to the Mac: the address is shut out.
      server.accept();
      server.close(Close.unauthorized, "unauthorized");
      return new Response(null, { status: 101, webSocket: client });
    }

    if (role === "data") {
      // A Mac data socket for one phone. It must present the phone's token as its first frame.
      const conn = parts[5]!;
      this.ctx.acceptWebSocket(server, [`data:${conn}`]);
      server.serializeAttachment({
        role,
        id,
        conn,
        authed: false,
        paired: false,
        ip,
        deadline: Date.now() + PAIR_TIMEOUT_MS,
      } satisfies Attachment);
      await this.rearm();
      return new Response(null, { status: 101, webSocket: client });
    }

    const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
    if (role === "host") {
      this.ctx.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ role, id, nonce, authed: false, paired: false, ip, deadline } satisfies Attachment);
    } else {
      const conn = b64url(crypto.getRandomValues(new Uint8Array(16)));
      this.ctx.acceptWebSocket(server, [`phone:${conn}`]);
      if (ip) {
        this.recentPhones.set(conn, ip);
        if (this.recentPhones.size > 64) this.recentPhones.delete(this.recentPhones.keys().next().value!);
      }
      server.serializeAttachment({ role, id, conn, nonce, authed: false, paired: false, ip, deadline } satisfies Attachment);
    }
    server.send(encodeControl({ t: "challenge", nonce }));
    await this.rearm();
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
    const att = ws.deserializeAttachment() as Attachment | null;
    this.closePeer(ws);
    this.safeClose(ws, sendableCode(code), "closed");
    if (att?.role === "host" && att.authed) await this.ctx.storage.put("lastUsed", Date.now());
    if (att?.deadline !== undefined || att?.role === "host") await this.rearm();
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.closePeer(ws);
  }

  private async hostMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    const frame = parseText(message);
    if (!frame) return ws.close(Close.protocol, "protocol");

    if (att.authed) {
      if (frame.t === "badHandshake") return this.recordBadHandshake(frame.conn);
      return ws.close(Close.protocol, "protocol");
    }

    if (frame.t === "claim") return this.claim(ws, att, frame.hostKey, frame.accessKey, frame.sig);
    if (frame.t === "auth") return this.auth(ws, att, frame.sig);
    return ws.close(Close.protocol, "protocol");
  }

  /** A phone sends one `access` frame, then nothing until it is paired; after that everything is forwarded. */
  private async phoneMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message, MAX_PHONE_FRAME) > MAX_PHONE_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      if (await this.overBudget(ws, att, message)) return;
      const data = this.pairedSocket(`data:${att.conn}`);
      if (!data || !this.safeSend(data, message)) return ws.close(Close.macOffline, "mac offline");
      return;
    }
    const frame = att.authed ? null : parseText(message);
    if (!frame || frame.t !== "access") return ws.close(Close.protocol, "protocol");

    const accessKey = await this.ctx.storage.get<string>("accessKey");
    if (!accessKey) return ws.close(Close.noMailbox, "no such mailbox");
    await this.loadBudget();
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
    if (this.budgetSpent()) return this.sendLimitAndClose([ws]);

    let waiting = 0;
    let pairedCount = 0;
    for (const other of this.ctx.getWebSockets()) {
      const o = other.deserializeAttachment() as Attachment | null;
      if (!o || o.role !== "phone" || !o.authed || other.readyState !== WebSocket.READY_STATE_OPEN) continue;
      if (o.paired) pairedCount++;
      else waiting++;
    }
    if (waiting >= MAX_WAITING || waiting + pairedCount >= MAX_PHONES) {
      ws.send(encodeControl({ t: "error", code: "busy", message: "Too many phones are connected to this Mac." }));
      return ws.close(Close.limit, "busy");
    }

    const token = b64url(crypto.getRandomValues(new Uint8Array(32)));
    ws.serializeAttachment({
      ...now,
      authed: true,
      token,
      nonce: undefined,
      deadline: Date.now() + PAIR_TIMEOUT_MS,
    } satisfies Attachment);
    ws.send(encodeControl({ t: "waiting" }));
    this.safeSend(host, encodeControl({ t: "phone", conn: att.conn!, token }));
    await this.rearm();
  }

  /** A data socket sends one `data` frame with the phone's token, then frames pass to that phone. */
  private async dataMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message, MAX_MAC_FRAME) > MAX_MAC_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      if (await this.overBudget(ws, att, message)) return;
      const phone = this.pairedSocket(`phone:${att.conn}`);
      if (!phone || !this.safeSend(phone, message)) return ws.close(Close.protocol, "no phone");
      return;
    }
    const frame = parseText(message);
    if (!frame || frame.t !== "data") return ws.close(Close.protocol, "protocol");

    // No await between the token check and consuming it, so a token pairs at most once.
    const phone = this.ctx.getWebSockets(`phone:${att.conn}`)[0];
    const pAtt = phone?.deserializeAttachment() as Attachment | null | undefined;
    if (!phone || !pAtt || pAtt.paired || !pAtt.authed || !pAtt.token || !sameString(pAtt.token, frame.token)) {
      return ws.close(Close.unauthorized, "unauthorized");
    }
    phone.serializeAttachment({ ...pAtt, paired: true, token: undefined, deadline: undefined } satisfies Attachment);
    ws.serializeAttachment({ ...att, authed: true, paired: true, deadline: undefined } satisfies Attachment);
    this.safeSend(phone, encodeControl({ t: "paired" }));
    await this.rearm();
  }

  /** The socket with this tag that has completed pairing, if any. Unpaired sockets are never a peer. */
  private pairedSocket(tag: string): WebSocket | undefined {
    return this.ctx
      .getWebSockets(tag)
      .find((w) => w.readyState === WebSocket.READY_STATE_OPEN && (w.deserializeAttachment() as Attachment | null)?.paired);
  }

  /**
   * Closes the other half of a pair. Only a paired socket has a peer: a phone that is still waiting, or a data
   * socket that never proved the token, closing or failing affects nobody else.
   */
  private closePeer(ws: WebSocket) {
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att || !att.paired || (att.role !== "phone" && att.role !== "data")) return;
    const peerTag = att.role === "phone" ? `data:${att.conn}` : `phone:${att.conn}`;
    const peer = this.pairedSocket(peerTag);
    if (peer) this.safeClose(peer, 1000, "peer closed");
  }

  private closeBoth(ws: WebSocket, _att: Attachment, code: number, reason: string) {
    this.closePeer(ws);
    this.safeClose(ws, code, reason);
  }

  /** Sends to a socket that may be closing. Returns false, and never throws, when the message did not go. */
  private safeSend(ws: WebSocket, message: string | ArrayBuffer): boolean {
    if (ws.readyState !== WebSocket.READY_STATE_OPEN) return false;
    try {
      ws.send(message);
      return true;
    } catch {
      return false;
    }
  }

  private safeClose(ws: WebSocket, code: number, reason: string) {
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  private async claim(ws: WebSocket, att: Attachment, hostKey: string, accessKey: string, sig: string) {
    if (att.ip) {
      // The limiter is named by a hash of the address, so the address itself is never stored.
      const limiter = this.env.CLAIM_LIMITER.getByName(await hashAddress(att.ip));
      if (!(await limiter.hit())) {
        this.safeSend(ws, encodeControl({ t: "error", code: "limit", message: "Too many claims from this address." }));
        return ws.close(Close.limit, "limit");
      }
    }
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return ws.close(Close.unauthorized, "unauthorized");
    // The signature check awaited, so look again before writing: the first claim wins.
    if (await this.ctx.storage.get("hostKey")) return ws.close(Close.taken, "taken");
    await this.ctx.storage.put({ hostKey, accessKey, lastUsed: Date.now() });
    await this.becomeHost(ws, att);
  }

  private async auth(ws: WebSocket, att: Attachment, sig: string) {
    const hostKey = await this.ctx.storage.get<string>("hostKey");
    if (!hostKey) return ws.close(Close.noMailbox, "no such mailbox");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return ws.close(Close.unauthorized, "unauthorized");
    await this.ctx.storage.put("lastUsed", Date.now());
    await this.becomeHost(ws, att);
  }

  /** Marks this socket as the control socket and closes any older one. */
  private async becomeHost(ws: WebSocket, att: Attachment) {
    for (const other of this.ctx.getWebSockets("host")) {
      if (other === ws) continue;
      const otherAtt = other.deserializeAttachment() as Attachment | null;
      if (otherAtt?.authed) {
        // Mark it signed out first: it can linger in getWebSockets until its close handshake ends.
        other.serializeAttachment({ ...otherAtt, authed: false } satisfies Attachment);
        this.safeClose(other, Close.taken, "replaced");
      }
    }
    ws.serializeAttachment({ ...att, authed: true, nonce: undefined, deadline: undefined } satisfies Attachment);
    ws.send(encodeControl({ t: "ready" }));
    await this.rearm();
  }

  // Bad handshakes -----------------------------------------------------------------------------------------

  private isBlocked(ip: string): boolean {
    const e = this.failures.get(ip);
    if (!e) return false;
    if (e.blockedUntil > Date.now()) return true;
    if (e.blockedUntil !== 0) this.failures.delete(ip);
    return false;
  }

  /** The Mac says the phone with this connection id failed its handshake. Counted by the phone's address. */
  private recordBadHandshake(conn: string) {
    const phone = this.ctx.getWebSockets(`phone:${conn}`)[0];
    const ip = (phone?.deserializeAttachment() as Attachment | null | undefined)?.ip || this.recentPhones.get(conn);
    this.recentPhones.delete(conn);
    if (!ip) return;
    const now = Date.now();
    let e = this.failures.get(ip);
    if (!e || (e.blockedUntil === 0 && now - e.since > BLOCK_MS) || (e.blockedUntil !== 0 && e.blockedUntil <= now)) {
      if (!e && this.failures.size >= 1024) this.trimFailures(now);
      e = { count: 0, since: now, blockedUntil: 0 };
      this.failures.set(ip, e);
    }
    e.count++;
    if (e.count >= FAILURES_BEFORE_BLOCK) e.blockedUntil = now + BLOCK_MS;
  }

  private trimFailures(now: number) {
    for (const [ip, e] of this.failures) {
      if (e.blockedUntil !== 0 ? e.blockedUntil <= now : now - e.since > BLOCK_MS) this.failures.delete(ip);
    }
    while (this.failures.size >= 1024) this.failures.delete(this.failures.keys().next().value!);
  }

  // Daily budget -------------------------------------------------------------------------------------------

  /** Reads the stored counts once per wake. */
  loadBudget(): Promise<void> {
    this.budgetLoading ??= (async () => {
      const stored = await this.ctx.storage.get<Budget>("budget");
      if (stored) this.budget = stored;
    })();
    return this.budgetLoading;
  }

  private rollBudget() {
    const day = today();
    if (this.budget.day !== day) this.budget = { day, messages: 0, bytes: 0 };
  }

  /** True when today's counts are already used up, so no new pairing should start. */
  private budgetSpent(): boolean {
    this.rollBudget();
    return this.budget.messages >= DAILY_MESSAGES || this.budget.bytes >= DAILY_BYTES;
  }

  /**
   * Counts one incoming message. Past either limit, both sides of the pair get the limit frame and close with 4029.
   * Text is charged by its UTF-16 length (at most a third of its UTF-8 size), which is exact for the JSON the app sends.
   */
  private async overBudget(ws: WebSocket, att: Attachment, message: string | ArrayBuffer): Promise<boolean> {
    await this.loadBudget();
    this.rollBudget();
    this.budget.messages++;
    this.budget.bytes += typeof message === "string" ? message.length : message.byteLength;
    const over = this.budget.messages > DAILY_MESSAGES || this.budget.bytes > DAILY_BYTES;
    // Writing the day as spent right away is what stops a reconnect from starting over.
    await this.noteTraffic(over);
    if (!over) return false;
    const peerTag = att.role === "phone" ? `data:${att.conn}` : `phone:${att.conn}`;
    this.sendLimitAndClose([ws, this.pairedSocket(peerTag)]);
    return true;
  }

  private sendLimitAndClose(sockets: Array<WebSocket | undefined>) {
    const frame = encodeControl({ t: "limit", kind: "daily", resetsAt: (this.budget.day + 1) * (DAY_MS / 1000) });
    for (const s of sockets) {
      if (!s) continue;
      this.safeSend(s, frame);
      this.safeClose(s, Close.limit, "limit");
    }
  }

  /** Writes the counts at most once a minute, or at once when `force` is set (the day has just been spent). */
  private async noteTraffic(force: boolean) {
    if (force || Date.now() - this.lastFlush >= BUDGET_FLUSH_MS) return this.flushBudget();
    if (!this.budgetDirty) {
      this.budgetDirty = true;
      await this.rearm();
    }
  }

  private async flushBudget() {
    this.lastFlush = Date.now();
    this.budgetDirty = false;
    this.budgetWrites++;
    await this.ctx.storage.put("budget", { ...this.budget });
  }

  // The alarm ----------------------------------------------------------------------------------------------

  /**
   * Points the single alarm at the earliest pending deadline: a handshake timeout, the delayed budget write, or the
   * clean-up 90 days after the Mac was last seen. Deadlines are read from attachments and storage, so this holds after
   * eviction. With nothing pending but the clean-up, the alarm is that clean-up and the object still hibernates.
   */
  private async rearm() {
    let next: number | null = null;
    const consider = (t: number | undefined) => {
      if (t !== undefined && (next === null || t < next)) next = t;
    };
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.READY_STATE_OPEN) continue;
      consider((ws.deserializeAttachment() as Attachment | null)?.deadline);
    }
    if (this.budgetDirty) consider(this.lastFlush + BUDGET_FLUSH_MS);
    const lastUsed = await this.ctx.storage.get<number>("lastUsed");
    if (lastUsed !== undefined) consider(lastUsed + IDLE_DELETE_MS);

    const current = await this.ctx.storage.getAlarm();
    if (next === null) {
      if (current !== null) await this.ctx.storage.deleteAlarm();
    } else if (current !== next) {
      await this.ctx.storage.setAlarm(next);
    }
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    let hostConnected = false;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.READY_STATE_OPEN) continue;
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att?.role === "host" && att.authed) hostConnected = true;
      if (att?.deadline !== undefined && att.deadline <= now) {
        ws.serializeAttachment({ ...att, deadline: undefined } satisfies Attachment);
        this.safeClose(ws, Close.timeout, "timeout");
      }
    }
    if (this.budgetDirty && now - this.lastFlush >= BUDGET_FLUSH_MS) await this.flushBudget();

    const lastUsed = await this.ctx.storage.get<number>("lastUsed");
    if (lastUsed !== undefined && now >= lastUsed + IDLE_DELETE_MS) {
      if (hostConnected) {
        // A Mac that has stayed connected is in use, however long ago it signed in.
        await this.ctx.storage.put("lastUsed", now);
      } else {
        for (const ws of this.ctx.getWebSockets()) this.safeClose(ws, Close.noMailbox, "no such mailbox");
        await this.ctx.storage.deleteAlarm();
        await this.ctx.storage.deleteAll();
        this.budget = { day: today(), messages: 0, bytes: 0 };
        this.budgetLoading = null;
        this.budgetDirty = false;
        return;
      }
    }
    await this.rearm();
  }
}

async function hashAddress(ip: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(`ensemble-relay-ip|${ip}`)));
  return b64url(digest.subarray(0, 16));
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

/**
 * Size in bytes, to compare with `cap`. Text is encoded only when its length cannot decide: a string never needs more
 * than 3 UTF-8 bytes per UTF-16 unit, and never fewer than 1. In the two shortcut cases the result is a bound on the
 * true size that falls on the same side of `cap` as the true size.
 */
function byteLength(message: string | ArrayBuffer, cap: number): number {
  if (typeof message !== "string") return message.byteLength;
  if (message.length > cap) return message.length;
  if (message.length * 3 <= cap) return message.length * 3;
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
