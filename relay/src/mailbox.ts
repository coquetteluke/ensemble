import { DurableObject } from "cloudflare:workers";
import { addressKey } from "./address";
import {
  BLOCK_MS,
  BUDGET_FLUSH_MS,
  CHALLENGE_TIMEOUT_MS,
  DAILY_BYTES,
  DAILY_MESSAGES,
  FAILURES_BEFORE_BLOCK,
  IDLE_DELETE_MS,
  MAX_PHONES,
  MAX_TRACKED_ADDRESSES,
  MAX_UNPROVEN_PER_ADDRESS,
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
  /**
   * Host and phone only: the hash of the normalized source address (see address.ts). The address itself is never kept.
   * A phone keeps it so the Mac's badHandshake can be tied to its source.
   */
  addr?: string;
  /** Paired phone and data sockets: incoming messages and bytes not yet added to the stored budget. */
  dMsgs?: number;
  dBytes?: number;
  /** Unix ms by which this socket must finish what it is waiting for, or it is closed with 4008. */
  deadline?: number;
}

/** Incoming traffic for one UTC day, as stored. Unflushed counts live in the sockets' attachments. */
interface Budget {
  day: number;
  messages: number;
  bytes: number;
  /** Unix ms of the last write, kept here so "at most once a minute" holds across hibernation. */
  lastFlush: number;
  /** Writes so far, so tests can count them across evictions. */
  writes: number;
  /** The day on which the Mac was told the budget is spent. */
  notifiedDay: number;
}

/** Failures reported for one source address. */
interface Fail {
  count: number;
  since: number;
  blockedUntil: number;
}

function freshBudget(): Budget {
  return { day: today(), messages: 0, bytes: 0, lastFlush: 0, writes: 0, notifiedDay: -1 };
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
 * - budget: the day's incoming message and byte counts, written at most once a minute. Counts not yet written sit in
 *   the paired sockets' attachments, which survive hibernation, and are added in at the next write or at close.
 * - fails: bad-handshake counts and blocks by address hash, with expiry
 *
 * The one alarm serves three deadlines and is always set to the earliest: pending handshake timeouts, a delayed
 * budget write, and the 90-day clean-up. With nothing pending, only the clean-up alarm remains.
 */
export class Mailbox extends DurableObject<Env> {
  /** The stored budget, loaded once per wake. Public so tests can set it. */
  budget: Budget = freshBudget();
  private budgetLoading: Promise<void> | null = null;
  private failLock: Promise<unknown> = Promise.resolve();
  /** The last few phones' address hashes by connection id, for a report that arrives after the phone left. */
  private recentPhones = new Map<string, string>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const parts = new URL(request.url).pathname.split("/");
    const id = parts[3]!;
    const role = parts[4];
    const addr = await addressKey(request.headers.get("CF-Connecting-IP") ?? "");
    if (role !== "host" && role !== "phone" && role !== "data") return new Response("not found", { status: 404 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    const deadline = Date.now() + CHALLENGE_TIMEOUT_MS;

    if (role === "phone" && addr !== "") {
      // A blocked address gets no challenge and the Mac hears nothing. An address may also hold only a few
      // connections that have not yet proved the access key, so none can be opened ahead of time in bulk.
      const blocked = await this.isBlocked(addr);
      const unproven = blocked
        ? 0
        : this.ctx.getWebSockets().filter((w) => {
            const a = w.deserializeAttachment() as Attachment | null;
            return w.readyState === WebSocket.READY_STATE_OPEN && a?.role === "phone" && !a.authed && a.addr === addr;
          }).length;
      if (blocked || unproven >= MAX_UNPROVEN_PER_ADDRESS) {
        server.accept();
        this.safeClose(server, blocked ? Close.unauthorized : Close.limit, blocked ? "unauthorized" : "busy");
        return new Response(null, { status: 101, webSocket: client });
      }
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
        deadline: Date.now() + PAIR_TIMEOUT_MS,
      } satisfies Attachment);
      await this.rearm();
      return new Response(null, { status: 101, webSocket: client });
    }

    const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
    if (role === "host") {
      this.ctx.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ role, id, nonce, authed: false, paired: false, addr, deadline } satisfies Attachment);
    } else {
      const conn = b64url(crypto.getRandomValues(new Uint8Array(16)));
      this.ctx.acceptWebSocket(server, [`phone:${conn}`]);
      server.serializeAttachment({ role, id, conn, nonce, authed: false, paired: false, addr, deadline } satisfies Attachment);
    }
    this.safeSend(server, encodeControl({ t: "challenge", nonce }));
    await this.rearm();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (!att) return this.safeClose(ws, Close.protocol, "protocol");
      if (att.role === "phone") return await this.phoneMessage(ws, att, message);
      if (att.role === "data") return await this.dataMessage(ws, att, message);
      return await this.hostMessage(ws, att, message);
    } catch {
      // Nothing may escape a handler: a failure here ends only this socket.
      this.safeClose(ws, 1011, "error");
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment | null;
    this.closePeer(ws);
    this.safeClose(ws, sendableCode(code), "closed");
    try {
      if (att?.role === "host" && att.authed) await this.ctx.storage.put("lastUsed", Date.now());
      // Counts this socket has not yet written would vanish with it, so they go into the stored budget now.
      if (att?.dMsgs || att?.dBytes) await this.foldClosing(ws, att);
      if (att?.deadline !== undefined || att?.role === "host") await this.rearm();
    } catch {
      // Storage trouble must not surface from a close handler.
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.closePeer(ws);
  }

  private async hostMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    const frame = parseText(message);
    if (!frame) return this.safeClose(ws, Close.protocol, "protocol");

    if (att.authed) {
      if (frame.t === "badHandshake") return this.recordBadHandshake(frame.conn);
      return this.safeClose(ws, Close.protocol, "protocol");
    }

    if (frame.t === "claim") return this.claim(ws, att, frame.hostKey, frame.accessKey, frame.sig);
    if (frame.t === "auth") return this.auth(ws, att, frame.sig);
    return this.safeClose(ws, Close.protocol, "protocol");
  }

  /** A phone sends one `access` frame, then nothing until it is paired; after that everything is forwarded. */
  private async phoneMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message, MAX_PHONE_FRAME) > MAX_PHONE_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      if (await this.overBudget(ws, att, message)) return;
      const data = this.pairedSocket(`data:${att.conn}`);
      if (!data || !this.safeSend(data, message)) return this.safeClose(ws, Close.macOffline, "mac offline");
      return;
    }
    const frame = att.authed ? null : parseText(message);
    if (!frame || frame.t !== "access") return this.safeClose(ws, Close.protocol, "protocol");

    const accessKey = await this.ctx.storage.get<string>("accessKey");
    if (!accessKey) return this.safeClose(ws, Close.noMailbox, "no such mailbox");
    await this.loadBudget();
    if (!(await verifyPhone(accessKey, frame.proof, att.id, att.nonce!))) {
      return this.safeClose(ws, Close.unauthorized, "unauthorized");
    }
    // An address can be blocked after it connected, so look again just before the Mac would be told about it.
    if (att.addr && (await this.isBlocked(att.addr))) return this.safeClose(ws, Close.unauthorized, "unauthorized");
    // The proof check awaited. Re-read the attachment so a repeated `access` frame cannot mint a second token.
    const now = ws.deserializeAttachment() as Attachment | null;
    if (!now || ws.readyState !== WebSocket.READY_STATE_OPEN) return;
    // A second `access` frame, sent before the first finished, is a frame before paired.
    if (now.authed) return this.safeClose(ws, Close.protocol, "protocol");

    const host = this.ctx
      .getWebSockets("host")
      .find((h) => h.readyState === WebSocket.READY_STATE_OPEN && (h.deserializeAttachment() as Attachment | null)?.authed);
    if (!host) {
      this.safeSend(ws, encodeControl({ t: "error", code: "macOffline", message: "The Mac is offline." }));
      return this.safeClose(ws, Close.macOffline, "mac offline");
    }
    if (this.budgetSpent()) {
      this.limitUnpaired(ws);
      return this.tellHostBudgetSpent();
    }

    let waiting = 0;
    let pairedCount = 0;
    for (const other of this.ctx.getWebSockets()) {
      const o = other.deserializeAttachment() as Attachment | null;
      if (!o || o.role !== "phone" || !o.authed || other.readyState !== WebSocket.READY_STATE_OPEN) continue;
      if (o.paired) pairedCount++;
      else waiting++;
    }
    if (waiting >= MAX_WAITING || waiting + pairedCount >= MAX_PHONES) {
      this.safeSend(ws, encodeControl({ t: "error", code: "busy", message: "Too many phones are connected to this Mac." }));
      return this.safeClose(ws, Close.limit, "busy");
    }

    const token = b64url(crypto.getRandomValues(new Uint8Array(32)));
    ws.serializeAttachment({
      ...now,
      authed: true,
      token,
      nonce: undefined,
      deadline: Date.now() + PAIR_TIMEOUT_MS,
    } satisfies Attachment);
    this.safeSend(ws, encodeControl({ t: "waiting" }));
    this.safeSend(host, encodeControl({ t: "phone", conn: att.conn!, token }));
    // Only phones the Mac was told about are remembered, and at most MAX_WAITING are in that state at once.
    if (att.addr) {
      this.recentPhones.set(att.conn!, att.addr);
      if (this.recentPhones.size > 64) this.recentPhones.delete(this.recentPhones.keys().next().value!);
    }
    await this.rearm();
  }

  /** A data socket sends one `data` frame with the phone's token, then frames pass to that phone. */
  private async dataMessage(ws: WebSocket, att: Attachment, message: string | ArrayBuffer) {
    if (att.paired) {
      if (byteLength(message, MAX_MAC_FRAME) > MAX_MAC_FRAME) return this.closeBoth(ws, att, Close.tooBig, "too big");
      if (await this.overBudget(ws, att, message)) return;
      const phone = this.pairedSocket(`phone:${att.conn}`);
      if (!phone || !this.safeSend(phone, message)) return this.safeClose(ws, Close.protocol, "no phone");
      return;
    }
    const frame = parseText(message);
    if (!frame || frame.t !== "data") return this.safeClose(ws, Close.protocol, "protocol");

    // No await between the token check and consuming it, so a token pairs at most once.
    const phone = this.ctx.getWebSockets(`phone:${att.conn}`)[0];
    const pAtt = phone?.deserializeAttachment() as Attachment | null | undefined;
    if (!phone || !pAtt || pAtt.paired || !pAtt.authed || !pAtt.token || !sameString(pAtt.token, frame.token)) {
      return this.safeClose(ws, Close.unauthorized, "unauthorized");
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
    if (att.addr) {
      // The limiter is named by the address hash, so the address itself is never stored. If it cannot answer, the
      // claim is refused rather than let through unchecked.
      let allowed = false;
      try {
        allowed = await this.env.CLAIM_LIMITER.getByName(att.addr).hit();
      } catch {
        allowed = false;
      }
      if (!allowed) {
        this.safeSend(ws, encodeControl({ t: "error", code: "limit", message: "Too many claims from this address." }));
        return this.safeClose(ws, Close.limit, "limit");
      }
    }
    if (await this.ctx.storage.get("hostKey")) return this.safeClose(ws, Close.taken, "taken");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return this.safeClose(ws, Close.unauthorized, "unauthorized");
    // The signature check awaited, so look again before writing: the first claim wins.
    if (await this.ctx.storage.get("hostKey")) return this.safeClose(ws, Close.taken, "taken");
    await this.ctx.storage.put({ hostKey, accessKey, lastUsed: Date.now() });
    await this.becomeHost(ws, att);
  }

  private async auth(ws: WebSocket, att: Attachment, sig: string) {
    const hostKey = await this.ctx.storage.get<string>("hostKey");
    if (!hostKey) return this.safeClose(ws, Close.noMailbox, "no such mailbox");
    if (!(await verifyHost(hostKey, sig, att.id, att.nonce!))) return this.safeClose(ws, Close.unauthorized, "unauthorized");
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
    this.safeSend(ws, encodeControl({ t: "ready" }));
    await this.rearm();
  }

  // Bad handshakes -----------------------------------------------------------------------------------------

  private expired(f: Fail, now: number): boolean {
    return f.blockedUntil !== 0 ? f.blockedUntil <= now : now - f.since > BLOCK_MS;
  }

  private async isBlocked(key: string): Promise<boolean> {
    if (key === "") return false;
    const f = (await this.ctx.storage.get<Record<string, Fail>>("fails"))?.[key];
    return f !== undefined && f.blockedUntil > Date.now();
  }

  /** The Mac says the phone with this connection id failed its handshake. Counted by the phone's address hash. */
  private async recordBadHandshake(conn: string) {
    const phone = this.ctx.getWebSockets(`phone:${conn}`)[0];
    const key = (phone?.deserializeAttachment() as Attachment | null | undefined)?.addr || this.recentPhones.get(conn);
    this.recentPhones.delete(conn);
    if (!key) return;
    // One at a time, so two reports cannot both read the same stored count.
    const run = this.failLock.then(() => this.addFailure(key));
    this.failLock = run.catch(() => undefined);
    await run;
  }

  /** Written to storage so hibernation cannot clear it. Only failures and expiry write, and both are rare. */
  private async addFailure(key: string) {
    const now = Date.now();
    const fails = (await this.ctx.storage.get<Record<string, Fail>>("fails")) ?? {};
    for (const [k, f] of Object.entries(fails)) if (this.expired(f, now)) delete fails[k];
    const f = fails[key] ?? { count: 0, since: now, blockedUntil: 0 };
    f.count++;
    if (f.count >= FAILURES_BEFORE_BLOCK) f.blockedUntil = now + BLOCK_MS;
    fails[key] = f;
    const keys = Object.keys(fails);
    if (keys.length > MAX_TRACKED_ADDRESSES) {
      keys.sort((a, b) => fails[a]!.since - fails[b]!.since);
      for (const k of keys.slice(0, keys.length - MAX_TRACKED_ADDRESSES)) delete fails[k];
    }
    await this.ctx.storage.put("fails", fails);
    await this.rearm();
  }

  private async pruneFails(now: number) {
    const fails = await this.ctx.storage.get<Record<string, Fail>>("fails");
    if (!fails) return;
    for (const [k, f] of Object.entries(fails)) if (this.expired(f, now)) delete fails[k];
    if (Object.keys(fails).length === 0) await this.ctx.storage.delete("fails");
    else await this.ctx.storage.put("fails", fails);
  }

  // Daily budget -------------------------------------------------------------------------------------------

  /** Reads the stored counts once per wake. */
  loadBudget(): Promise<void> {
    this.budgetLoading ??= (async () => {
      const stored = await this.ctx.storage.get<Budget>("budget");
      if (stored) this.budget = { ...freshBudget(), ...stored };
    })();
    return this.budgetLoading;
  }

  private rollBudget() {
    if (this.budget.day !== today()) this.budget = { ...freshBudget(), writes: this.budget.writes };
  }

  /** Every paired socket's unwritten counts, from the attachments. */
  private pending(): { messages: number; bytes: number } {
    let messages = 0;
    let bytes = 0;
    for (const w of this.ctx.getWebSockets()) {
      const a = w.deserializeAttachment() as Attachment | null;
      messages += a?.dMsgs ?? 0;
      bytes += a?.dBytes ?? 0;
    }
    return { messages, bytes };
  }

  private hasPending(): boolean {
    const p = this.pending();
    return p.messages > 0 || p.bytes > 0;
  }

  /** True when today's counts, written and unwritten, are used up, so no new pairing should start. */
  private budgetSpent(): boolean {
    this.rollBudget();
    const p = this.pending();
    return this.budget.messages + p.messages >= DAILY_MESSAGES || this.budget.bytes + p.bytes >= DAILY_BYTES;
  }

  private resetsAt(): number {
    return (this.budget.day + 1) * (DAY_MS / 1000);
  }

  /**
   * Counts one incoming message in its socket's attachment, which survives hibernation. Past either limit the pair
   * is ended with close 4029 (nothing is injected into the forwarded stream, where the other side could fake it),
   * waiting phones and the Mac's control socket are told with a `limit` frame, and the day is written at once.
   */
  private async overBudget(ws: WebSocket, att: Attachment, message: string | ArrayBuffer): Promise<boolean> {
    await this.loadBudget();
    this.rollBudget();
    const first = !att.dMsgs && !att.dBytes;
    const size = typeof message === "string" ? enc.encode(message).byteLength : message.byteLength;
    ws.serializeAttachment({ ...att, dMsgs: (att.dMsgs ?? 0) + 1, dBytes: (att.dBytes ?? 0) + size } satisfies Attachment);
    const p = this.pending();
    const over = this.budget.messages + p.messages > DAILY_MESSAGES || this.budget.bytes + p.bytes > DAILY_BYTES;

    if (over) {
      this.tellHostBudgetSpent(false);
      await this.flushBudget();
      const reason = `limit ${this.resetsAt()}`;
      const peerTag = att.role === "phone" ? `data:${att.conn}` : `phone:${att.conn}`;
      for (const s of [ws, this.pairedSocket(peerTag)]) if (s) this.safeClose(s, Close.limit, reason);
      for (const s of this.ctx.getWebSockets()) {
        const a = s.deserializeAttachment() as Attachment | null;
        if (a?.role === "phone" && a.authed && !a.paired) this.limitUnpaired(s);
      }
      return true;
    }
    if (Date.now() - this.budget.lastFlush >= BUDGET_FLUSH_MS) await this.flushBudget();
    else if (first) await this.rearm();
    return false;
  }

  /** A phone that has not paired is on a control socket, so it may be told with a frame. */
  private limitUnpaired(ws: WebSocket) {
    this.safeSend(ws, encodeControl({ t: "limit", kind: "daily", resetsAt: this.resetsAt() }));
    this.safeClose(ws, Close.limit, `limit ${this.resetsAt()}`);
  }

  /** Tells the Mac's control socket once per spent day. `write` stores the mark; the caller flushes otherwise. */
  private async tellHostBudgetSpent(write = true) {
    if (this.budget.notifiedDay === this.budget.day) return;
    const host = this.ctx
      .getWebSockets("host")
      .find((h) => h.readyState === WebSocket.READY_STATE_OPEN && (h.deserializeAttachment() as Attachment | null)?.authed);
    if (!host) return;
    this.budget.notifiedDay = this.budget.day;
    this.safeSend(host, encodeControl({ t: "limit", kind: "daily", resetsAt: this.resetsAt() }));
    if (write) await this.flushBudget();
  }

  /** Adds every socket's unwritten counts to the stored totals, zeroes them, and writes. */
  private async flushBudget() {
    await this.loadBudget();
    this.rollBudget();
    const p = this.pending();
    this.budget.messages += p.messages;
    this.budget.bytes += p.bytes;
    for (const w of this.ctx.getWebSockets()) {
      const a = w.deserializeAttachment() as Attachment | null;
      if (!a || (!a.dMsgs && !a.dBytes)) continue;
      try {
        w.serializeAttachment({ ...a, dMsgs: undefined, dBytes: undefined } satisfies Attachment);
      } catch {
        // A socket that is already gone has nothing left to zero.
      }
    }
    this.budget.lastFlush = Date.now();
    this.budget.writes++;
    await this.ctx.storage.put("budget", this.budget);
  }

  /** A closing socket's own counts go into the stored totals before they are lost with it. */
  private async foldClosing(ws: WebSocket, att: Attachment) {
    await this.loadBudget();
    this.rollBudget();
    this.budget.messages += att.dMsgs ?? 0;
    this.budget.bytes += att.dBytes ?? 0;
    try {
      ws.serializeAttachment({ ...att, dMsgs: undefined, dBytes: undefined } satisfies Attachment);
    } catch {
      // Already gone.
    }
    await this.flushBudget();
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
    await this.loadBudget();
    if (this.hasPending()) consider(this.budget.lastFlush + BUDGET_FLUSH_MS);
    const fails = await this.ctx.storage.get<Record<string, Fail>>("fails");
    for (const f of Object.values(fails ?? {})) consider(f.blockedUntil !== 0 ? f.blockedUntil : f.since + BLOCK_MS);
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
    await this.loadBudget();
    if (this.hasPending() && now - this.budget.lastFlush >= BUDGET_FLUSH_MS) await this.flushBudget();
    await this.pruneFails(now);

    const lastUsed = await this.ctx.storage.get<number>("lastUsed");
    if (lastUsed !== undefined && now >= lastUsed + IDLE_DELETE_MS) {
      if (hostConnected) {
        // A Mac that has stayed connected is in use, however long ago it signed in.
        await this.ctx.storage.put("lastUsed", now);
      } else {
        for (const ws of this.ctx.getWebSockets()) this.safeClose(ws, Close.noMailbox, "no such mailbox");
        await this.ctx.storage.deleteAlarm();
        await this.ctx.storage.deleteAll();
        this.budget = freshBudget();
        this.budgetLoading = null;
        return;
      }
    }
    await this.rearm();
  }
}

/** Checks the host's Ed25519 signature over `ensemble-relay-host|<id>|<nonce>`. Exported for the shared vectors test. */
export async function verifyHost(hostKeyB64: string, sigB64: string, id: string, nonce: string): Promise<boolean> {
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

/** Checks a phone's HMAC-SHA256 proof over `ensemble-relay-phone|<id>|<nonce>`. Exported for the shared vectors test. */
export async function verifyPhone(accessKeyB64: string, proofB64: string, id: string, nonce: string): Promise<boolean> {
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
