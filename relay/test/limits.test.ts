import { env, evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { addressKey } from "../src/address";
import { BLOCK_MS, DAILY_BYTES, DAILY_MESSAGES, IDLE_DELETE_MS, MAX_TRACKED_ADDRESSES } from "../src/limits";
import type { Mailbox } from "../src/mailbox";
import {
  auth,
  b64url,
  claim,
  type Client,
  connect,
  dataSocket,
  type Mac,
  newKey,
  paired,
  phoneWaiting,
  proof,
  randomID,
  setup,
} from "./helpers";

const stubOf = (mac: Mac) => env.MAILBOX.getByName(mac.id);

/** A phone from a given address that has proved the access key. Returns the phone and what the Mac was told. */
async function phoneFrom(mac: Mac, ip: string) {
  const phone = await connect(mac.id, "phone", ip);
  const ch = await phone.next();
  phone.send({ t: "access", proof: await proof(mac.accessKey, mac.id, ch.nonce) });
  return phone;
}

describe("phone limits", () => {
  it("at most 3 phones wait at once", async () => {
    const mac = await setup();
    for (let i = 0; i < 3; i++) await phoneWaiting(mac);
    const fourth = await phoneFrom(mac, "203.0.113.1");
    expect(await fourth.next()).toMatchObject({ t: "error", code: "busy" });
    expect(await fourth.closeCode()).toBe(4029);
    expect(await mac.host.quiet()).toBe(true);
  });

  it("at most 8 phones are paired at once", async () => {
    const mac = await setup();
    for (let i = 0; i < 8; i++) await paired(mac);
    const ninth = await phoneFrom(mac, "203.0.113.2");
    expect(await ninth.next()).toMatchObject({ t: "error", code: "busy" });
    expect(await ninth.closeCode()).toBe(4029);
  });

  it("a paired phone leaves room for a waiting one", async () => {
    const mac = await setup();
    for (let i = 0; i < 3; i++) await paired(mac);
    for (let i = 0; i < 3; i++) await phoneWaiting(mac);
  });
});

describe("timeouts close with 4008", () => {
  it.concurrent("a host that never answers the challenge", { timeout: 30_000 }, async () => {
    const host = await connect(randomID(), "host");
    await host.next();
    expect(await host.closeCode(25_000)).toBe(4008);
  });

  it.concurrent("a phone that never answers the challenge", { timeout: 30_000 }, async () => {
    const mac = await setup();
    const phone = await connect(mac.id, "phone");
    await phone.next();
    expect(await phone.closeCode(25_000)).toBe(4008);
    expect(await mac.host.quiet()).toBe(true);
  });

  it.concurrent("a waiting phone that is never paired, even after eviction", { timeout: 30_000 }, async () => {
    const mac = await setup();
    const { phone } = await phoneWaiting(mac);
    await evictDurableObject(stubOf(mac));
    expect(await phone.closeCode(25_000)).toBe(4008);
  });

  it.concurrent("a data socket that never sends its token", { timeout: 30_000 }, async () => {
    const mac = await setup();
    const data = await connect(mac.id, `data/${b64url(crypto.getRandomValues(new Uint8Array(16)))}`);
    expect(await data.closeCode(25_000)).toBe(4008);
  });

  it.concurrent("a pair that completed is not closed by a stale timer", { timeout: 30_000 }, async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await new Promise((r) => setTimeout(r, 16_000));
    expect(phone.closed).toBeNull();
    expect(data.closed).toBeNull();
    phone.ws.send("x");
    expect(await data.nextRaw()).toBe("x");
  });

  it("an idle mailbox has only the clean-up alarm", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    const alarm = await runInDurableObject(stubOf(mac), (_i, state) => state.storage.getAlarm());
    expect(alarm).not.toBeNull();
    expect(alarm! - Date.now()).toBeGreaterThan(IDLE_DELETE_MS - 60_000);
    phone.ws.close(1000);
    await data.closeCode();
  });
});

describe("bad handshakes block an address", () => {
  it("five reports from one address block it, another address still works", { timeout: 20_000 }, async () => {
    const mac = await setup();
    for (let i = 0; i < 5; i++) {
      const phone = await phoneFrom(mac, "198.51.100.9");
      expect(await phone.next()).toEqual({ t: "waiting" });
      const note = await mac.host.next();
      mac.host.send({ t: "badHandshake", conn: note.conn });
      phone.ws.close(1000);
      await phone.closeCode();
    }
    expect(await mac.host.quiet()).toBe(true);

    const blocked = await connect(mac.id, "phone", "198.51.100.9");
    expect(await blocked.closeCode()).toBe(4001);
    expect(blocked.messages).toEqual([]);
    expect(await mac.host.quiet()).toBe(true);

    const other = await phoneFrom(mac, "198.51.100.10");
    expect(await other.next()).toEqual({ t: "waiting" });
    expect((await mac.host.next()).t).toBe("phone");
  });

  it("four reports do not block", async () => {
    const mac = await setup();
    for (let i = 0; i < 4; i++) {
      const phone = await phoneFrom(mac, "198.51.100.20");
      await phone.next();
      mac.host.send({ t: "badHandshake", conn: (await mac.host.next()).conn });
      phone.ws.close(1000);
      await phone.closeCode();
    }
    const fifth = await phoneFrom(mac, "198.51.100.20");
    expect(await fifth.next()).toEqual({ t: "waiting" });
  });

  it("a badHandshake for an unknown connection is ignored", async () => {
    const mac = await setup();
    mac.host.send({ t: "badHandshake", conn: b64url(crypto.getRandomValues(new Uint8Array(16))) });
    expect(await mac.host.quiet()).toBe(true);
  });

  it("active blocks survive table saturation by counting-only entries", async () => {
    const mac = await setup();
    const blockedIP = "198.51.100.50";
    for (let i = 0; i < 5; i++) {
      const phone = await phoneFrom(mac, blockedIP);
      expect(await phone.next()).toEqual({ t: "waiting" });
      const note = await mac.host.next();
      mac.host.send({ t: "badHandshake", conn: note.conn });
      phone.ws.close(1000);
      await phone.closeCode();
    }
    await mac.host.quiet(50);

    // Fill the remaining slots with newer unblocked counting entries, then report fresh failures.
    const blockedKey = await addressKey(blockedIP);
    await runInDurableObject(stubOf(mac), async (_inst, state) => {
      const fails = (await state.storage.get<Record<string, { count: number; since: number; blockedUntil: number }>>("fails")) ?? {};
      const base = Date.now();
      for (let i = 0; Object.keys(fails).length < MAX_TRACKED_ADDRESSES; i++) {
        fails[`counting-${i}`] = { count: 1, since: base + i, blockedUntil: 0 };
      }
      await state.storage.put("fails", fails);
    });

    for (let i = 0; i < 5; i++) {
      const phone = await phoneFrom(mac, `198.51.101.${i + 1}`);
      expect(await phone.next()).toEqual({ t: "waiting" });
      const note = await mac.host.next();
      mac.host.send({ t: "badHandshake", conn: note.conn });
      phone.ws.close(1000);
      await phone.closeCode();
    }
    await mac.host.quiet(50);

    const blocked = await connect(mac.id, "phone", blockedIP);
    expect(await blocked.closeCode()).toBe(4001);

    // When all slots hold active blocks, a new unblocked counting entry is refused instead of evicting a block.
    await runInDurableObject(stubOf(mac), async (_inst, state) => {
      const now = Date.now();
      const fullBlocks: Record<string, { count: number; since: number; blockedUntil: number }> = {
        [blockedKey]: { count: 5, since: now - 10_000, blockedUntil: now + BLOCK_MS },
      };
      for (let i = 1; i < MAX_TRACKED_ADDRESSES; i++) {
        fullBlocks[`block-${i}`] = { count: 5, since: now - 5_000 + i, blockedUntil: now + BLOCK_MS };
      }
      await state.storage.put("fails", fullBlocks);
    });

    const newcomerIP = "198.51.102.99";
    const newcomer = await phoneFrom(mac, newcomerIP);
    expect(await newcomer.next()).toEqual({ t: "waiting" });
    const newcomerNote = await mac.host.next();
    mac.host.send({ t: "badHandshake", conn: newcomerNote.conn });
    newcomer.ws.close(1000);
    await newcomer.closeCode();
    await mac.host.quiet(50);

    const newcomerKey = await addressKey(newcomerIP);
    const storedFails = await runInDurableObject(stubOf(mac), (_inst, state) =>
      state.storage.get<Record<string, { count: number; since: number; blockedUntil: number }>>("fails"),
    );
    expect(Object.keys(storedFails!)).toHaveLength(MAX_TRACKED_ADDRESSES);
    expect(storedFails![blockedKey]).toBeDefined();
    expect(storedFails![newcomerKey]).toBeUndefined();
  });

  it("exact-expiry fails are removed by alarm without looping or rewriting untouched entries", async () => {
    const mac = await setup();
    await runInDurableObject(stubOf(mac), async (inst: Mailbox, state) => {
      const priv = inst as unknown as {
        expired(f: { count: number; since: number; blockedUntil: number }, now: number): boolean;
        pruneFails(now: number): Promise<void>;
        rearm(): Promise<void>;
      };
      const base = 1_000_000;
      expect(priv.expired({ count: 1, since: base, blockedUntil: 0 }, base + BLOCK_MS - 1)).toBe(false);
      expect(priv.expired({ count: 1, since: base, blockedUntil: 0 }, base + BLOCK_MS)).toBe(true);

      // Non-expired entries do not trigger a redundant storage write in pruneFails.
      const freshNow = Date.now();
      await state.storage.put("fails", { active: { count: 1, since: freshNow, blockedUntil: 0 } });
      const putSpy = vi.spyOn(state.storage, "put");
      const delSpy = vi.spyOn(state.storage, "delete");
      await priv.pruneFails(freshNow + 1000);
      expect(putSpy).not.toHaveBeenCalled();
      expect(delSpy).not.toHaveBeenCalled();
      putSpy.mockRestore();
      delSpy.mockRestore();

      // An entry that reached exact BLOCK_MS age is deleted and leaves only the 90-day clean-up alarm.
      await state.storage.put("fails", { stale: { count: 1, since: freshNow - BLOCK_MS, blockedUntil: 0 } });
      await priv.rearm();
    });

    expect(await runDurableObjectAlarm(stubOf(mac))).toBe(true);
    const [failsAfter, alarmAfter] = await runInDurableObject(stubOf(mac), async (_inst, state) => [
      await state.storage.get("fails"),
      await state.storage.getAlarm(),
    ]);
    expect(failsAfter).toBeUndefined();
    expect(alarmAfter).not.toBeNull();
    expect(alarmAfter! - Date.now()).toBeGreaterThan(IDLE_DELETE_MS - 60_000);
  });
});

describe("daily budget", () => {
  const nextMidnight = () => (Math.floor(Date.now() / 86_400_000) + 1) * 86_400;
  /** Sets the stored counts, as if that much of the day had been used. */
  const prime = (mac: Mac, patch: { messages?: number; bytes?: number }) =>
    runInDurableObject(stubOf(mac), async (inst: Mailbox, state) => {
      await inst.loadBudget();
      Object.assign(inst.budget, patch);
      await state.storage.put("budget", inst.budget);
    });
  const stored = (mac: Mac) =>
    runInDurableObject(stubOf(mac), (_i, state) => state.storage.get<{ messages: number; bytes: number; writes: number; lastFlush: number }>("budget"));

  /** A pair ends with close 4029 and a reason carrying the reset time. Nothing is injected into the stream. */
  async function expectPairEnded(c: Client) {
    expect(await c.closeCode()).toBe(4029);
    expect(c.closed!.reason).toBe(`limit ${nextMidnight()}`);
    expect(c.messages).toEqual([]);
  }

  it("past 40,000 messages the pair ends with 4029 and the Mac is told on its control socket", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { messages: DAILY_MESSAGES - 1 });
    phone.ws.send("last one");
    expect(await data.nextRaw()).toBe("last one");
    data.ws.send("over");
    await expectPairEnded(phone);
    await expectPairEnded(data);
    expect(await mac.host.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
  });

  it("past 200 MB the pair ends with 4029", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { bytes: DAILY_BYTES - 10 });
    phone.ws.send(new Uint8Array(100));
    await expectPairEnded(phone);
    await expectPairEnded(data);
  });

  it("a waiting phone is told with a limit frame when the day is spent", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    const { phone: waiting } = await phoneWaiting(mac);
    await prime(mac, { messages: DAILY_MESSAGES });
    phone.ws.send("over");
    await expectPairEnded(data);
    expect(await waiting.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
    expect(await waiting.closeCode()).toBe(4029);
  });

  it("reconnecting does not reset the counters; the Mac is told once", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { messages: DAILY_MESSAGES });
    phone.ws.send("over");
    await expectPairEnded(data);
    expect((await mac.host.next()).t).toBe("limit");

    await evictDurableObject(stubOf(mac));
    const again = await phoneFrom(mac, "203.0.113.50");
    expect(await again.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
    expect(await again.closeCode()).toBe(4029);
    expect(await mac.host.quiet()).toBe(true);
  });

  it("a reconnecting host after the daily budget is spent immediately receives limit after ready", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { messages: DAILY_MESSAGES });
    phone.ws.send("over");
    await expectPairEnded(data);
    expect(await mac.host.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });

    mac.host.ws.close(1000);
    await mac.host.closeCode();
    await evictDurableObject(stubOf(mac));

    const reconnected = await auth(mac.id, mac.key);
    expect(await reconnected.next()).toEqual({ t: "ready" });
    expect(await reconnected.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });

    const blockedPhone = await phoneFrom(mac, "203.0.113.51");
    expect(await blockedPhone.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
    expect(await blockedPhone.closeCode()).toBe(4029);
    expect(await reconnected.quiet()).toBe(true);
  });

  it("webSocketError folds unflushed counts, closes the peer, and updates lastUsed on host error", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    for (let i = 0; i < 4; i++) {
      phone.ws.send(`m${i}`);
      await data.nextRaw();
    }
    await runInDurableObject(stubOf(mac), async (inst: Mailbox, state) => {
      const phoneWs = state.getWebSockets().find((w) => {
        const a = w.deserializeAttachment() as { role?: string } | null;
        return a?.role === "phone";
      })!;
      await inst.webSocketError(phoneWs);
    });
    expect(await data.closeCode()).toBe(1000);
    expect(await phone.closeCode()).toBe(1000);
    expect((await stored(mac))!.messages).toBe(4);

    await runInDurableObject(stubOf(mac), async (inst: Mailbox, state) => {
      await state.storage.put("lastUsed", 1);
      const hostWs = state.getWebSockets("host")[0]!;
      await inst.webSocketError(hostWs);
    });
    expect(await mac.host.closeCode()).toBe(1000);
    const lastUsed = await runInDurableObject(stubOf(mac), (_inst, state) => state.storage.get<number>("lastUsed"));
    expect(lastUsed).toBeGreaterThan(1);
  });

  it("unwritten counts survive hibernation and reach storage with the alarm", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    for (let i = 0; i < 5; i++) {
      phone.ws.send(`m${i}`);
      await data.nextRaw();
    }
    await evictDurableObject(stubOf(mac));
    for (let i = 0; i < 5; i++) {
      data.ws.send(`n${i}`);
      await phone.nextRaw();
    }
    await evictDurableObject(stubOf(mac));
    // Make the minute since the last write pass, then let the alarm do the write.
    await runInDurableObject(stubOf(mac), async (inst: Mailbox, state) => {
      await inst.loadBudget();
      inst.budget.lastFlush = Date.now() - 61_000;
      await state.storage.put("budget", inst.budget);
    });
    expect(await runDurableObjectAlarm(stubOf(mac))).toBe(true);
    expect((await stored(mac))!.messages).toBe(10);
  });

  it("messages spaced past hibernation still cost at most one write a minute", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    for (let i = 0; i < 6; i++) {
      phone.ws.send(`m${i}`);
      expect(await data.nextRaw()).toBe(`m${i}`);
      await evictDurableObject(stubOf(mac));
    }
    expect((await stored(mac))!.writes).toBe(1);
  });

  it("a closing socket's counts are added to the stored totals", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    for (let i = 0; i < 4; i++) {
      phone.ws.send(`m${i}`);
      await data.nextRaw();
    }
    phone.ws.close(1000);
    await data.closeCode();
    expect((await stored(mac))!.messages).toBe(4);
  });

  it("text is charged by its UTF-8 size", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    phone.ws.send("\u20ac\u20ac"); // 6 bytes
    await data.nextRaw();
    phone.ws.close(1000);
    await data.closeCode();
    expect((await stored(mac))!.bytes).toBe(6);
  });
});

describe("claim rate per address", () => {
  it("the eleventh claim in an hour from one address closes 4029", async () => {
    const ip = "192.0.2.77";
    for (let i = 0; i < 10; i++) {
      const c = await claim(randomID(), await newKey(), undefined, ip);
      expect((await c.next()).t).toBe("ready");
    }
    const eleventh = await claim(randomID(), await newKey(), undefined, ip);
    expect(await eleventh.closeCode()).toBe(4029);

    const other = await claim(randomID(), await newKey(), undefined, "192.0.2.78");
    expect((await other.next()).t).toBe("ready");
  });
});

describe("idle clean-up", () => {
  async function age(mac: Mac, ms: number) {
    await runInDurableObject(stubOf(mac), (_i, state) => state.storage.put("lastUsed", Date.now() - ms));
  }

  it("an alarm 90 days after lastUsed deletes the mailbox", async () => {
    const mac = await setup();
    mac.host.ws.close(1000);
    await mac.host.closeCode();
    await age(mac, IDLE_DELETE_MS + 1000);
    expect(await runDurableObjectAlarm(stubOf(mac))).toBe(true);
    const keys = await runInDurableObject(stubOf(mac), (_i, state) => state.storage.list());
    expect([...keys.keys()]).toEqual([]);

    const again = await auth(mac.id, mac.key);
    expect(await again.closeCode()).toBe(4004);
  });

  it("a mailbox whose Mac is still connected is kept", async () => {
    const mac = await setup();
    await age(mac, IDLE_DELETE_MS + 1000);
    await runDurableObjectAlarm(stubOf(mac));
    const hostKey = await runInDurableObject(stubOf(mac), (_i, state) => state.storage.get("hostKey"));
    expect(hostKey).toBeDefined();
  });

  it("a mailbox used recently is kept", async () => {
    const mac = await setup();
    mac.host.ws.close(1000);
    await mac.host.closeCode();
    await age(mac, IDLE_DELETE_MS - 3600_000);
    await runDurableObjectAlarm(stubOf(mac));
    const again = await auth(mac.id, mac.key);
    expect((await again.next()).t).toBe("ready");
  });
});

describe("peer closing", () => {
  it("closing one side closes the other with 1000, not the closing side's code", async () => {
    const mac = await setup();
    const a = await paired(mac);
    a.phone.ws.close(4123, "custom");
    expect(await a.data.closeCode()).toBe(1000);

    const b = await paired(mac);
    b.data.ws.close(4222, "custom");
    expect(await b.phone.closeCode()).toBe(1000);
  });

  it("a frame over the cap closes the other side with 1000 as well", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    phone.ws.send(new Uint8Array(1024 * 1024 + 1));
    expect(await phone.closeCode()).toBe(4013);
    expect(await data.closeCode()).toBe(1000);
  });

  it("sending to a closing or throwing peer does not throw", async () => {
    const mac = await setup();
    const results = await runInDurableObject(stubOf(mac), (inst: Mailbox) => {
      const send = (inst as unknown as { safeSend(ws: unknown, m: string): boolean }).safeSend.bind(inst);
      const closing = { readyState: WebSocket.READY_STATE_CLOSING, send: () => { throw new Error("closed"); } };
      const throwing = { readyState: WebSocket.READY_STATE_OPEN, send: () => { throw new Error("closed"); } };
      return [send(closing, "x"), send(throwing, "x")];
    });
    expect(results).toEqual([false, false]);
  });
});

describe("bad handshake state survives hibernation", () => {
  async function badReport(mac: Mac, ip: string) {
    const phone = await phoneFrom(mac, ip);
    expect(await phone.next()).toEqual({ t: "waiting" });
    const note = await mac.host.next();
    mac.host.send({ t: "badHandshake", conn: note.conn });
    await mac.host.quiet(50);
    phone.ws.close(1000);
    await phone.closeCode();
  }

  it("five failures with an eviction between each still block, and the block outlasts eviction", async () => {
    const mac = await setup();
    for (let i = 0; i < 5; i++) {
      await badReport(mac, "198.51.100.40");
      await evictDurableObject(stubOf(mac));
    }
    const blocked = await connect(mac.id, "phone", "198.51.100.40");
    expect(await blocked.closeCode()).toBe(4001);
    expect(blocked.messages).toEqual([]);
  });

  it("an address blocked after it connected gets no phone notice", async () => {
    const mac = await setup();
    const early = await connect(mac.id, "phone", "198.51.100.41");
    const ch = await early.next();
    for (let i = 0; i < 5; i++) await badReport(mac, "198.51.100.41");
    early.send({ t: "access", proof: await proof(mac.accessKey, mac.id, ch.nonce) });
    expect(await early.closeCode()).toBe(4001);
    expect(await mac.host.quiet()).toBe(true);
  });

  it("one address cannot hold more than 3 unproven connections", async () => {
    const mac = await setup();
    const held: Client[] = [];
    for (let i = 0; i < 3; i++) {
      const c = await connect(mac.id, "phone", "198.51.100.42");
      await c.next();
      held.push(c);
    }
    const fourth = await connect(mac.id, "phone", "198.51.100.42");
    expect(await fourth.closeCode()).toBe(4029);
    const other = await connect(mac.id, "phone", "198.51.100.43");
    expect((await other.next()).t).toBe("challenge");
  });

  it("a flood of throwaway connects does not stop a late badHandshake from counting", async () => {
    const mac = await setup();
    const conns: string[] = [];
    for (let i = 0; i < 5; i++) {
      const phone = await phoneFrom(mac, "198.51.100.44");
      await phone.next();
      const note = await mac.host.next();
      conns.push(note.conn);
      phone.ws.close(1000);
      await phone.closeCode();
    }
    for (let i = 0; i < 70; i++) await connect(mac.id, "phone", `203.0.113.${100 + (i % 100)}`);
    for (const conn of conns) mac.host.send({ t: "badHandshake", conn });
    await mac.host.quiet(100);
    const blocked = await connect(mac.id, "phone", "198.51.100.44");
    expect(await blocked.closeCode()).toBe(4001);
  });
});

describe("claims by IPv6 prefix", () => {
  it("addresses in one /64 share the claim limit", async () => {
    for (let i = 0; i < 10; i++) {
      const c = await claim(randomID(), await newKey(), undefined, `2001:db8:1:2::${i + 1}`);
      expect((await c.next()).t).toBe("ready");
    }
    const eleventh = await claim(randomID(), await newKey(), undefined, "2001:db8:1:2:ffff::9");
    expect(await eleventh.closeCode()).toBe(4029);
  });

  it("missing CF-Connecting-IP fails closed and still hits claim and unproven limits", async () => {
    const mac = await setup();
    const held: Client[] = [];
    for (let i = 0; i < 3; i++) {
      const c = await connect(mac.id, "phone");
      await c.next();
      held.push(c);
    }
    const fourth = await connect(mac.id, "phone");
    expect(await fourth.closeCode()).toBe(4029);

    for (let i = 0; i < 10; i++) {
      const c = await claim(randomID(), await newKey());
      expect((await c.next()).t).toBe("ready");
    }
    const eleventh = await claim(randomID(), await newKey());
    expect(await eleventh.closeCode()).toBe(4029);
  });
});
