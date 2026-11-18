import { b64url } from "./wire";

/**
 * The part of an address that counts as one source: the full address for IPv4, the /64 prefix for IPv6 (one host
 * usually holds a whole /64, so the full address would let it dodge every per-address limit). An IPv4-mapped IPv6
 * address counts as its IPv4 address. Returns "" for anything that is not an address.
 */
export function normalizeAddress(ip: string): string {
  const s = ip.trim().toLowerCase();
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s)) return s;
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (mapped) return mapped[1]!;
  if (!s.includes(":") || !/^[0-9a-f:.]+$/.test(s)) return "";

  const halves = s.split("::");
  if (halves.length > 2) return "";
  const head = halves[0] === "" ? [] : halves[0]!.split(":");
  const tail = halves.length === 2 && halves[1] !== "" ? halves[1]!.split(":") : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return "";
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...tail];
  if (groups.length !== 8 || !groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return "";
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

/** A short hash of the normalized address. Addresses themselves are never stored, logged or used as names. */
export async function addressKey(ip: string): Promise<string> {
  const norm = normalizeAddress(ip);
  if (norm === "") return "";
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`ensemble-relay-ip|${norm}`)));
  return b64url(digest.subarray(0, 16));
}
