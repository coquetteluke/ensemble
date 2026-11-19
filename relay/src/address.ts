import { b64url } from "./wire";

function parseIPv4(s: string): number[] | null {
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(s)) return null;
  const octets: number[] = [];
  for (const part of s.split(".")) {
    if (part.length > 1 && part.startsWith("0")) return null;
    const value = Number(part);
    if (value < 0 || value > 255) return null;
    octets.push(value);
  }
  return octets;
}

/**
 * The part of an address that counts as one source: the full address for IPv4, the /64 prefix for IPv6 (one host
 * usually holds a whole /64, so the full address would let it dodge every per-address limit). An IPv4-mapped IPv6
 * address counts as its IPv4 address. Returns "" for anything that is not an address.
 */
export function normalizeAddress(ip: string): string {
  let s = ip.trim().toLowerCase();
  if (s === "") return "";

  // Strip a valid IPv6 zone suffix (`<ipv6>%<zone>`). Pure IPv4 does not carry a zone suffix.
  const pct = s.indexOf("%");
  if (pct !== -1) {
    const zone = s.slice(pct + 1);
    s = s.slice(0, pct);
    if (!s.includes(":") || !/^[0-9a-z._-]+$/.test(zone)) return "";
  }

  if (parseIPv4(s)) return s;
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (mapped) return parseIPv4(mapped[1]!) ? mapped[1]! : "";
  if (!s.includes(":") || !/^[0-9a-f:.]+$/.test(s)) return "";

  if (s.includes(".")) {
    const lastColon = s.lastIndexOf(":");
    const octets = parseIPv4(s.slice(lastColon + 1));
    if (!octets) return "";
    const hi = ((octets[0]! << 8) | octets[1]!).toString(16);
    const lo = ((octets[2]! << 8) | octets[3]!).toString(16);
    s = `${s.slice(0, lastColon + 1)}${hi}:${lo}`;
  }

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

/**
 * A short hash of the normalized address, or of the raw trimmed input when normalization fails so missing or
 * malformed addresses still map to a non-empty key and never bypass limits. Addresses themselves are never stored,
 * logged or used as names.
 */
export async function addressKey(ip: string): Promise<string> {
  const norm = normalizeAddress(ip);
  const input = norm !== "" ? `ensemble-relay-ip|${norm}` : `ensemble-relay-ip-raw|${ip.trim().toLowerCase()}`;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
  return b64url(digest.subarray(0, 16));
}
