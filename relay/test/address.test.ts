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
  });

  it("returns nothing for text that is not an address", () => {
    expect(normalizeAddress("")).toBe("");
    expect(normalizeAddress("not-an-ip")).toBe("");
    expect(normalizeAddress("1:2:3")).toBe("");
    expect(normalizeAddress("1::2::3")).toBe("");
  });

  it("hashes addresses in one /64 to the same key and others differently", async () => {
    expect(await addressKey("2001:db8:1:2::1")).toBe(await addressKey("2001:db8:1:2:9::9"));
    expect(await addressKey("2001:db8:1:3::1")).not.toBe(await addressKey("2001:db8:1:2::1"));
    expect(await addressKey("")).toBe("");
  });
});
