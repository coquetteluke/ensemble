import { env, evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { DAILY_BYTES, DAILY_MESSAGES, IDLE_DELETE_MS } from "../src/limits";
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
});

describe("daily budget", () => {
  const nextMidnight = () => (Math.floor(Date.now() / 86_400_000) + 1) * 86_400;
  const prime = (mac: Mac, patch: { messages?: number; bytes?: number }) =>
    runInDurableObject(stubOf(mac), async (inst: Mailbox) => {
      await inst.loadBudget();
      Object.assign(inst.budget, patch);
    });
  const writes = (mac: Mac) => runInDurableObject(stubOf(mac), (inst: Mailbox) => inst.budgetWrites);

  async function expectLimit(c: Client) {
    expect(await c.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
    expect(await c.closeCode()).toBe(4029);
  }

  it("past 40,000 messages both sides get a limit frame and close 4029", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { messages: DAILY_MESSAGES - 1 });
    phone.ws.send("last one");
    expect(await data.nextRaw()).toBe("last one");
    data.ws.send("over");
    await expectLimit(phone);
    await expectLimit(data);
  });

  it("past 200 MB both sides get a limit frame and close 4029", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { bytes: DAILY_BYTES - 10 });
    phone.ws.send(new Uint8Array(100));
    await expectLimit(phone);
    await expectLimit(data);
  });

  it("reconnecting does not reset the counters, even after eviction", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    await prime(mac, { messages: DAILY_MESSAGES });
    phone.ws.send("over");
    await expectLimit(phone);
    await expectLimit(data);

    await evictDurableObject(stubOf(mac));
    const again = await phoneFrom(mac, "203.0.113.50");
    expect(await again.next()).toEqual({ t: "limit", kind: "daily", resetsAt: nextMidnight() });
    expect(await again.closeCode()).toBe(4029);
  });

  it("counters reach storage at most once a minute", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    for (let i = 0; i < 30; i++) {
      phone.ws.send(`m${i}`);
      expect(await data.nextRaw()).toBe(`m${i}`);
    }
    expect(await writes(mac)).toBe(1);
    await prime(mac, { messages: DAILY_MESSAGES });
    phone.ws.send("over");
    await expectLimit(phone);
    // One more write marks the day as spent so a reconnect cannot reset it.
    expect(await writes(mac)).toBe(2);
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
