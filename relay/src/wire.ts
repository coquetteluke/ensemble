// Wire format shared by the relay, the Mac and the phone. See the relay design notes.

export const MAX_CONTROL_BYTES = 2048;

export type ErrorCode = "macOffline" | "unauthorized" | "taken" | "busy" | "tooBig" | "limit";

const ERROR_CODES: readonly string[] = ["macOffline", "unauthorized", "taken", "busy", "tooBig", "limit"];

export type ControlFrame =
  | { t: "challenge"; nonce: string }
  | { t: "claim"; hostKey: string; accessKey: string; sig: string }
  | { t: "auth"; sig: string }
  | { t: "ready" }
  | { t: "phone"; conn: string; token: string }
  | { t: "data"; token: string }
  | { t: "badHandshake"; conn: string }
  | { t: "access"; proof: string }
  | { t: "waiting" }
  | { t: "paired" }
  | { t: "limit"; kind: "daily"; resetsAt: number }
  | { t: "error"; code: ErrorCode; message: string };

/** Close codes the relay uses. */
export const Close = {
  unauthorized: 4001,
  protocol: 4002,
  noMailbox: 4004,
  timeout: 4008,
  taken: 4009,
  macOffline: 4010,
  tooBig: 4013,
  limit: 4029,
} as const;

const ID_RE = /^[A-Za-z0-9_-]{43}$/;
const CONN_RE = /^[A-Za-z0-9_-]{22}$/;

export function isMailboxID(s: string): boolean {
  return ID_RE.test(s);
}

export function isConnID(s: string): boolean {
  return CONN_RE.test(s);
}

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decodes unpadded base64url. Returns null for anything that is not the canonical encoding. */
export function fromB64url(s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) return null;
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  let raw: string;
  try {
    raw = atob(padded);
  } catch {
    return null;
  }
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return b64url(out) === s ? out : null;
}

/** True when `s` is base64url for exactly `n` bytes. */
function isB64(s: unknown, n: number): s is string {
  return typeof s === "string" && fromB64url(s)?.length === n;
}

function hasKeys(o: Record<string, unknown>, keys: string[]): boolean {
  const have = Object.keys(o);
  return have.length === keys.length && keys.every((k) => k in o);
}

/** Parses one control frame. Returns null for anything that is not exactly a frame from the table. */
export function parseControl(text: string): ControlFrame | null {
  // The UTF-16 length never exceeds the UTF-8 byte length, so a long string is rejected without encoding it.
  if (text.length > MAX_CONTROL_BYTES || new TextEncoder().encode(text).length > MAX_CONTROL_BYTES) return null;
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;

  switch (o.t) {
    case "challenge":
      return hasKeys(o, ["t", "nonce"]) && isB64(o.nonce, 32) ? { t: "challenge", nonce: o.nonce } : null;
    case "claim":
      return hasKeys(o, ["t", "hostKey", "accessKey", "sig"]) &&
        isB64(o.hostKey, 32) &&
        isB64(o.accessKey, 32) &&
        isB64(o.sig, 64)
        ? { t: "claim", hostKey: o.hostKey, accessKey: o.accessKey, sig: o.sig }
        : null;
    case "auth":
      return hasKeys(o, ["t", "sig"]) && isB64(o.sig, 64) ? { t: "auth", sig: o.sig } : null;
    case "ready":
      return hasKeys(o, ["t"]) ? { t: "ready" } : null;
    case "phone":
      return hasKeys(o, ["t", "conn", "token"]) && typeof o.conn === "string" && isConnID(o.conn) && isB64(o.token, 32)
        ? { t: "phone", conn: o.conn, token: o.token }
        : null;
    case "data":
      return hasKeys(o, ["t", "token"]) && isB64(o.token, 32) ? { t: "data", token: o.token } : null;
    case "badHandshake":
      return hasKeys(o, ["t", "conn"]) && typeof o.conn === "string" && isConnID(o.conn)
        ? { t: "badHandshake", conn: o.conn }
        : null;
    case "access":
      return hasKeys(o, ["t", "proof"]) && isB64(o.proof, 32) ? { t: "access", proof: o.proof } : null;
    case "waiting":
      return hasKeys(o, ["t"]) ? { t: "waiting" } : null;
    case "paired":
      return hasKeys(o, ["t"]) ? { t: "paired" } : null;
    case "limit":
      return hasKeys(o, ["t", "kind", "resetsAt"]) && o.kind === "daily" && Number.isInteger(o.resetsAt)
        ? { t: "limit", kind: "daily", resetsAt: o.resetsAt as number }
        : null;
    case "error":
      return hasKeys(o, ["t", "code", "message"]) &&
        typeof o.code === "string" &&
        ERROR_CODES.includes(o.code) &&
        typeof o.message === "string"
        ? { t: "error", code: o.code as ErrorCode, message: o.message }
        : null;
    default:
      return null;
  }
}

export function encodeControl(frame: ControlFrame): string {
  return JSON.stringify(frame);
}
