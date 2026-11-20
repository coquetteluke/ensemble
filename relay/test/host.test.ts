import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Mailbox } from "../src/mailbox";
import { auth, b64url, claim, connect, newKey, randomID, sign } from "./helpers";

describe("host socket", () => {
  it("rejects unknown routes", async () => {
    expect((await SELF.fetch("https://relay.test/v1/nope")).status).toBe(404);
    const id = randomID();
    expect((await SELF.fetch(`https://relay.test/v1/mailbox/${id}/host`)).status).toBe(426);
    const bad = await SELF.fetch("https://relay.test/v1/mailbox/short/host", { headers: { Upgrade: "websocket" } });
    expect(bad.status).toBe(404);
  });

  it("claims an unclaimed mailbox", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect(await first.next()).toEqual({ t: "ready" });
    first.ws.close(1000);

    const second = await auth(id, key);
    expect(await second.next()).toEqual({ t: "ready" });
  });

  it("refuses a wrong signature", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect((await first.next()).t).toBe("ready");

    const c = await auth(id, await newKey());
    expect(await c.closeCode()).toBe(4001);
  });

  it("refuses a second claim", async () => {
    const id = randomID();
    const first = await claim(id, await newKey());
    expect((await first.next()).t).toBe("ready");

    const other = await claim(id, await newKey());
    expect(await other.closeCode()).toBe(4009);
  });

  it("only one control socket", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect((await first.next()).t).toBe("ready");

    const second = await auth(id, key);
    expect((await second.next()).t).toBe("ready");
    expect(await first.closeCode()).toBe(4009);
  });

  it("closes on a malformed, binary or oversized control frame", async () => {
    for (const bad of ["not json", '{"t":"nope"}', '{"t":"auth"}', "x".repeat(5000), new Uint8Array([1, 2, 3])]) {
      const c = await connect(randomID());
      await c.next();
      c.ws.send(bad);
      expect(await c.closeCode()).toBe(4002);
    }
  });

  it("refuses auth on an unclaimed mailbox with 4004", async () => {
    const c = await auth(randomID(), await newKey());
    expect(await c.closeCode()).toBe(4004);
  });

  it("refuses a claim with a wrong signature with 4001", async () => {
    const id = randomID();
    const key = await newKey();
    const c = await connect(id);
    const ch = await c.next();
    const wrong = await sign(await newKey(), id, ch.nonce);
    c.send({ t: "claim", hostKey: key.pub, accessKey: b64url(crypto.getRandomValues(new Uint8Array(32))), sig: wrong });
    expect(await c.closeCode()).toBe(4001);

    // The failed claim left the mailbox unclaimed.
    const again = await claim(id, key);
    expect((await again.next()).t).toBe("ready");
  });

  it("a signature for one socket's nonce fails on another socket", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key);
    expect((await first.next()).t).toBe("ready");

    const a = await connect(id);
    const b = await connect(id);
    const chA = await a.next();
    const chB = await b.next();
    expect(chA.nonce).not.toBe(chB.nonce);
    b.send({ t: "auth", sig: await sign(key, id, chA.nonce) });
    expect(await b.closeCode()).toBe(4001);
  });

  it("an unauthenticated socket cannot evict the authenticated host", async () => {
    const id = randomID();
    const key = await newKey();
    const host = await claim(id, key);
    expect((await host.next()).t).toBe("ready");

    const intruder = await connect(id);
    await intruder.next();
    intruder.send({ t: "auth", sig: b64url(new Uint8Array(64)) });
    expect(await intruder.closeCode()).toBe(4001);
    expect(host.closed).toBeNull();
    expect(await host.quiet()).toBe(true);
    host.send({ t: "ready" });
    expect(await host.closeCode()).toBe(4002);
  });

  it("a closed host socket finishing auth does not evict the live host", async () => {
    const id = randomID();
    const key = await newKey();
    const live = await claim(id, key, undefined, "2001:db8:c9::1");
    expect((await live.next()).t).toBe("ready");

    const stub = env.MAILBOX.getByName(id);
    const second = await connect(id, "host", "2001:db8:c9::2");
    const ch = await second.next();
    const sig = await sign(key, id, ch.nonce);

    await runInDurableObject(stub, async (inst: Mailbox, state) => {
      await state.storage.put("lastUsed", 123);
      const pendingHost = state.getWebSockets("host").find((w) => {
        const a = w.deserializeAttachment() as { authed?: boolean } | null;
        return a?.authed === false;
      })!;
      // Close before auth finishes its awaits, simulating a disconnect during verifyHost.
      const authPromise = inst.webSocketMessage(pendingHost, JSON.stringify({ t: "auth", sig }));
      pendingHost.close(1000, "gone");
      await authPromise;
      expect(await state.storage.get<number>("lastUsed")).toBe(123);
    });

    expect(live.closed).toBeNull();
    expect(await live.quiet()).toBe(true);
    live.ws.close(1000);
    await live.closeCode();
  });

  it("pipelined duplicate auth frames on one host socket close with 4002", async () => {
    const id = randomID();
    const key = await newKey();
    const first = await claim(id, key, undefined, "2001:db8:c9::3");
    expect((await first.next()).t).toBe("ready");

    const second = await connect(id, "host", "2001:db8:c9::4");
    const ch = await second.next();
    const sig = await sign(key, id, ch.nonce);
    second.send({ t: "auth", sig });
    second.send({ t: "auth", sig });
    expect(await second.closeCode()).toBe(4002);
    expect(await first.closeCode()).toBe(4009);
  });
});
