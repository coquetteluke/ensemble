import { env, evictDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { b64url, claim, Client, connect, newKey, proof, randomID } from "./helpers";

interface Mac {
  id: string;
  accessKey: string;
  host: Client;
}

async function setup(): Promise<Mac> {
  const id = randomID();
  const accessKey = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const host = await claim(id, await newKey(), accessKey);
  expect((await host.next()).t).toBe("ready");
  return { id, accessKey, host };
}

/** Connects a phone and sends a valid proof. Returns once the phone is waiting. */
async function phoneWaiting(mac: Mac): Promise<{ phone: Client; conn: string; token: string }> {
  const phone = await connect(mac.id, "phone");
  const ch = await phone.next();
  expect(ch.t).toBe("challenge");
  phone.send({ t: "access", proof: await proof(mac.accessKey, mac.id, ch.nonce) });
  expect(await phone.next()).toEqual({ t: "waiting" });
  const note = await mac.host.next();
  expect(note.t).toBe("phone");
  return { phone, conn: note.conn, token: note.token };
}

async function dataSocket(mac: Mac, conn: string, token: string): Promise<Client> {
  const data = await connect(mac.id, `data/${conn}`);
  data.send({ t: "data", token });
  return data;
}

async function paired(mac: Mac) {
  const p = await phoneWaiting(mac);
  const data = await dataSocket(mac, p.conn, p.token);
  expect(await p.phone.next()).toEqual({ t: "paired" });
  return { ...p, data };
}

describe("phone pairing and forwarding", () => {
  it("a phone with the right proof is paired", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);

    phone.ws.send("hello");
    expect(await data.nextRaw()).toBe("hello");

    data.ws.send(new Uint8Array([1, 2, 3]));
    const got = await phone.nextRaw();
    expect(new Uint8Array(got as ArrayBuffer)).toEqual(new Uint8Array([1, 2, 3]));
  });

  it("a wrong proof is refused and the host hears nothing", async () => {
    const mac = await setup();
    const phone = await connect(mac.id, "phone");
    const ch = await phone.next();
    phone.send({ t: "access", proof: await proof(b64url(new Uint8Array(32)), mac.id, ch.nonce) });
    expect(await phone.closeCode()).toBe(4001);
    expect(await mac.host.quiet()).toBe(true);
  });

  it("a proof made for another socket's nonce is refused", async () => {
    const mac = await setup();
    const a = await connect(mac.id, "phone");
    const b = await connect(mac.id, "phone");
    const chA = await a.next();
    await b.next();
    b.send({ t: "access", proof: await proof(mac.accessKey, mac.id, chA.nonce) });
    expect(await b.closeCode()).toBe(4001);
    expect(await mac.host.quiet()).toBe(true);
  });

  it("a phone on an unclaimed mailbox is closed with 4004", async () => {
    const id = randomID();
    const phone = await connect(id, "phone");
    const ch = await phone.next();
    phone.send({ t: "access", proof: await proof(b64url(new Uint8Array(32)), id, ch.nonce) });
    expect(await phone.closeCode()).toBe(4004);
  });

  it("mac offline", async () => {
    const mac = await setup();
    mac.host.ws.close(1000);
    await mac.host.closeCode();
    const phone = await connect(mac.id, "phone");
    const ch = await phone.next();
    phone.send({ t: "access", proof: await proof(mac.accessKey, mac.id, ch.nonce) });
    const err = await phone.next();
    expect(err.t).toBe("error");
    expect(err.code).toBe("macOffline");
    expect(await phone.closeCode()).toBe(4010);
  });

  it("a data socket with a wrong token is refused", async () => {
    const mac = await setup();
    const { phone, conn } = await phoneWaiting(mac);
    const data = await dataSocket(mac, conn, b64url(crypto.getRandomValues(new Uint8Array(32))));
    expect(await data.closeCode()).toBe(4001);
    expect(phone.closed).toBeNull();
    expect(await phone.quiet()).toBe(true);
  });

  it("a data socket cannot attach to another phone's conn", async () => {
    const mac = await setup();
    const one = await phoneWaiting(mac);
    const two = await phoneWaiting(mac);
    const data = await dataSocket(mac, two.conn, one.token);
    expect(await data.closeCode()).toBe(4001);
    expect(await one.phone.quiet()).toBe(true);
    expect(await two.phone.quiet()).toBe(true);
  });

  it("a data socket for an unknown conn is refused", async () => {
    const mac = await setup();
    const data = await dataSocket(mac, b64url(crypto.getRandomValues(new Uint8Array(16))), b64url(new Uint8Array(32)));
    expect(await data.closeCode()).toBe(4001);
  });

  it("the token is single use", async () => {
    const mac = await setup();
    const { phone, conn, token, ...rest } = await paired(mac);
    void rest;
    const second = await dataSocket(mac, conn, token);
    expect(await second.closeCode()).toBe(4001);
    // The pair is unharmed.
    expect(phone.closed).toBeNull();
  });

  it("a data socket may only send its token frame first", async () => {
    const mac = await setup();
    const { phone, conn } = await phoneWaiting(mac);
    const data = await connect(mac.id, `data/${conn}`);
    data.ws.send("sneaky");
    expect(await data.closeCode()).toBe(4002);
    expect(await phone.quiet()).toBe(true);
  });

  it("frames before paired close the phone", async () => {
    const mac = await setup();
    const early = await connect(mac.id, "phone");
    await early.next();
    early.ws.send("hello");
    expect(await early.closeCode()).toBe(4002);

    const { phone } = await phoneWaiting(mac);
    phone.ws.send("too early");
    expect(await phone.closeCode()).toBe(4002);
  });

  it("nothing from the Mac reaches the phone before paired", async () => {
    const mac = await setup();
    const { phone, conn } = await phoneWaiting(mac);
    const data = await connect(mac.id, `data/${conn}`);
    data.ws.send("early");
    expect(await data.closeCode()).toBe(4002);
    expect(await phone.quiet()).toBe(true);
  });

  it("the phone closing closes the data socket", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    phone.ws.close(1000);
    await data.closeCode();
  });

  it("the data socket closing closes the phone", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    data.ws.close(1000);
    await phone.closeCode();
  });

  it("pairing survives hibernation", async () => {
    const mac = await setup();
    const { phone, conn, token } = await phoneWaiting(mac);
    await evictDurableObject(env.MAILBOX.getByName(mac.id));
    const data = await dataSocket(mac, conn, token);
    expect(await phone.next()).toEqual({ t: "paired" });

    await evictDurableObject(env.MAILBOX.getByName(mac.id));
    phone.ws.send("after");
    expect(await data.nextRaw()).toBe("after");
    data.ws.send("back");
    expect(await phone.nextRaw()).toBe("back");
  });

  it("a large mac frame passes", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    const big = new Uint8Array(5 * 1024 * 1024).fill(0xab);
    data.ws.send(big);
    const got = new Uint8Array((await phone.nextRaw()) as ArrayBuffer);
    expect(got.length).toBe(big.length);
    expect(got[0]).toBe(0xab);
    expect(got[got.length - 1]).toBe(0xab);
  });

  it("a phone frame over 1 MiB closes the phone with 4013", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    phone.ws.send(new Uint8Array(1024 * 1024)); // exactly the cap passes
    expect(((await data.nextRaw()) as ArrayBuffer).byteLength).toBe(1024 * 1024);
    phone.ws.send(new Uint8Array(1024 * 1024 + 1));
    expect(await phone.closeCode()).toBe(4013);
    await data.closeCode();
    expect(data.messages.length).toBe(0);
  });

  it("a text phone frame over 1 MiB in bytes closes the phone with 4013", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    phone.ws.send("é".repeat(600 * 1024)); // 600K characters, 1.2 MiB in UTF-8
    expect(await phone.closeCode()).toBe(4013);
    expect(data.messages.length).toBe(0);
  });

  it("a mac frame over 16 MiB closes both sides with 4013", async () => {
    const mac = await setup();
    const { phone, data } = await paired(mac);
    data.ws.send(new Uint8Array(16 * 1024 * 1024 + 1));
    expect(await data.closeCode()).toBe(4013);
    await phone.closeCode();
    expect(phone.messages.length).toBe(0);
  });
});
