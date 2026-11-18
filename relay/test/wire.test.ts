import { describe, expect, it } from "vitest";
import { b64url, fromB64url, isConnID, isMailboxID, parseControl } from "../src/wire";

const k32 = b64url(new Uint8Array(32).fill(7));
const k64 = b64url(new Uint8Array(64).fill(9));
const conn = b64url(new Uint8Array(16).fill(3));

describe("parseControl", () => {
  it("accepts every frame in the table", () => {
    const good = [
      { t: "challenge", nonce: k32 },
      { t: "claim", hostKey: k32, accessKey: k32, sig: k64 },
      { t: "auth", sig: k64 },
      { t: "ready" },
      { t: "phone", conn, token: k32 },
      { t: "data", token: k32 },
      { t: "badHandshake", conn },
      { t: "access", proof: k32 },
      { t: "waiting" },
      { t: "paired" },
      { t: "limit", kind: "daily", resetsAt: 1700000000 },
      { t: "error", code: "macOffline", message: "offline" },
    ];
    for (const f of good) expect(parseControl(JSON.stringify(f))).toEqual(f);
  });

  it("rejects extra keys, missing keys and wrong types", () => {
    expect(parseControl(JSON.stringify({ t: "ready", extra: 1 }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "auth" }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "auth", sig: 5 }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "access", proof: k64 }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "limit", kind: "daily", resetsAt: 1.5 }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "error", code: "weird", message: "x" }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "phone", conn: "short", token: k32 }))).toBeNull();
  });

  it("rejects non-objects, bad JSON and unknown types", () => {
    for (const s of ["", "nope", "[]", "null", "5", '"x"', '{"t":"zzz"}', "{}"]) expect(parseControl(s)).toBeNull();
  });

  it("rejects frames over 2 KiB", () => {
    expect(parseControl(JSON.stringify({ t: "error", code: "busy", message: "x".repeat(2100) }))).toBeNull();
    // Multi-byte text can exceed 2 KiB in bytes while staying under it in characters.
    expect(parseControl(JSON.stringify({ t: "error", code: "busy", message: "é".repeat(1100) }))).toBeNull();
  });

  it("rejects non-canonical base64url", () => {
    expect(parseControl(JSON.stringify({ t: "auth", sig: k64.slice(0, -1) + "B" }))).toBeNull();
    expect(parseControl(JSON.stringify({ t: "auth", sig: k64 + "=" }))).toBeNull();
  });
});

describe("identifiers and base64url", () => {
  it("validates mailbox and connection ids", () => {
    expect(isMailboxID(k32)).toBe(true);
    expect(isMailboxID(k32 + "a")).toBe(false);
    expect(isConnID(conn)).toBe(true);
    expect(isConnID(k32)).toBe(false);
    expect(isConnID("a/b" + conn.slice(3))).toBe(false);
  });

  it("round trips", () => {
    const bytes = crypto.getRandomValues(new Uint8Array(37));
    expect(fromB64url(b64url(bytes))).toEqual(bytes);
  });
});
