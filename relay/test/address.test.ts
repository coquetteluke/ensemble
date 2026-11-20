import { describe, expect, it } from "vitest";
import { addressKey, normalizeAddress } from "../src/address";

describe("normalizeAddress", () => {
  it("keeps a full IPv4 address", () => {
    expect(normalizeAddress("203.0.113.7")).toBe("203.0.113.7");
  });

  it("reduces IPv6 to its /64, compressed or not", () => {
    expect(normalizeAddress("2001:db8:1:2::1")).toBe("2001:db8:1:2::/64");
    expect(normalizeAddress("2001:0DB8:0001:0002:aaaa:bbbb:cccc:dddd")).toBe("2001:db8:1:2::/64");
    expect(normalizeAddress("2001:db8::5")).toBe("2001:db8:0:0::/64");
    expect(normalizeAddress("::1")).toBe("0:0:0:0::/64");
  });

  it("treats an IPv4-mapped IPv6 address as its IPv4 address", () => {
    expect(normalizeAddress("::ffff:203.0.113.7")).toBe("203.0.113.7");
    expect(normalizeAddress("::ffff:256.0.113.7")).toBe("");
    expect(normalizeAddress("256.0.113.7")).toBe("");
    expect(normalizeAddress("192.0.01.1")).toBe("");
  });

  it("normalizes IPv6 addresses with embedded IPv4 tails to their /64", () => {
    expect(normalizeAddress("2001:db8::192.0.2.1")).toBe("2001:db8:0:0::/64");
    expect(normalizeAddress("2001:db8:1:2::192.0.2.1")).toBe("2001:db8:1:2::/64");
    expect(normalizeAddress("64:ff9b::192.0.2.1")).toBe("64:ff9b:0:0::/64");
    expect(normalizeAddress("::ffff:0:192.0.2.1")).toBe("0:0:0:0::/64");
    expect(normalizeAddress("2001:db8:1:2:3:4:192.0.2.1")).toBe("2001:db8:1:2::/64");
    expect(normalizeAddress("2001:db8::256.0.2.1")).toBe("");
    expect(normalizeAddress("2001:db8:1:2:3:4:5:192.0.2.1")).toBe("");
  });

  it("handles valid IPv6 zone suffixes and rejects invalid ones", () => {
    expect(normalizeAddress("fe80::1%eth0")).toBe("fe80:0:0:0::/64");
    expect(normalizeAddress("fe80::1%en0")).toBe("fe80:0:0:0::/64");
    expect(normalizeAddress("fe80::1%")).toBe("");
    expect(normalizeAddress("fe80::1%eth 0")).toBe("");
    expect(normalizeAddress("fe80::1%a%b")).toBe("");
    expect(normalizeAddress("203.0.113.7%eth0")).toBe("");
  });

  it("returns nothing for text that is not an address", () => {
    expect(normalizeAddress("")).toBe("");
    expect(normalizeAddress("not-an-ip")).toBe("");
    expect(normalizeAddress("1:2:3")).toBe("");
    expect(normalizeAddress("1::2::3")).toBe("");
  });

  it("hashes addresses in one /64 to the same key and fails closed for malformed inputs", async () => {
    expect(await addressKey("2001:db8:1:2::1")).toBe(await addressKey("2001:db8:1:2:9::9"));
    expect(await addressKey("2001:db8:1:2::192.0.2.1")).toBe(await addressKey("2001:db8:1:2::1"));
    expect(await addressKey("2001:db8:1:3::1")).not.toBe(await addressKey("2001:db8:1:2::1"));
    const emptyKey = await addressKey("");
    const badKey = await addressKey("not-an-ip");
    expect(emptyKey).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(badKey).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(emptyKey).not.toBe(badKey);
    expect(await addressKey("  ")).toBe(emptyKey);
    expect(await addressKey("NOT-AN-IP")).toBe(badKey);
  });
});
