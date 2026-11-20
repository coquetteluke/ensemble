import { describe, expect, it } from "vitest";
import { verifyHost, verifyPhone } from "../src/mailbox";
import { b64url, fromB64url } from "../src/wire";
import { enc, proof } from "./helpers";

// Fixed vectors shared with the Mac and the phone. `RelayIdentityTests` in the Swift package checks the same inputs
// and outputs, so the two sides cannot drift apart. Inputs are counting bytes and the expected values are written
// in short pieces, so nothing here looks like a real key.

/** 32 bytes counting up from `start`. */
function counting(start: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, (_, i) => start + i);
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function fromHex(s: string): Uint8Array {
  return Uint8Array.from(s.match(/../g)!, (h) => parseInt(h, 16));
}

const mailboxID = b64url(counting(0));
const nonce = b64url(counting(32));
const hostSeed = counting(64);
const pairingToken = b64url(counting(96));

const expected = {
  accessKey: ["163b3003", "d153f7d3", "89a854db", "83247261", "cb8204e7", "ce16cebc", "4597f84e", "c95b0242"].join(""),
  phoneProof: ["02921705", "5be2ead1", "a209742b", "58c5d3d1", "920d1a1f", "5a0cf585", "90f5eef0", "6cc3be00"].join(""),
  hostPublicKey: ["2543b92f", "f1095511", "476adc83", "69db6ddc", "933665a1", "1978dda1", "404ee106", "6ca9559d"].join(""),
  hostSignature: [
    "d5a954cd", "2f2c1e4c", "a285ee4a", "7cff6396", "241803a0", "407c47f9", "df2ada7a", "4df57d30",
    "03cc60e5", "f9ce3296", "60bd98fc", "c2babdb9", "a6c95d7b", "ab9c3812", "98879887", "dda5eb05",
  ].join(""),
};

/** HKDF-SHA256(ikm: token UTF-8, salt: "ensemble-relay", info: "ensemble-relay-access", 32 bytes). */
async function accessKeyFor(token: string): Promise<Uint8Array> {
  const ikm = await crypto.subtle.importKey("raw", enc.encode(token), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode("ensemble-relay"), info: enc.encode("ensemble-relay-access") },
    ikm,
    256,
  );
  return new Uint8Array(bits);
}

/** An Ed25519 key from its 32-byte seed (PKCS #8 wrapping of the raw seed). */
async function hostKeyFromSeed(seed: Uint8Array): Promise<CryptoKey> {
  const prefix = fromHex("302e020100300506032b657004220420");
  const pkcs8 = new Uint8Array([...prefix, ...seed]);
  return (await crypto.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, ["sign"])) as CryptoKey;
}

describe("vectors shared with the apps", () => {
  it("inputs are what the Swift test builds", () => {
    expect(mailboxID).toHaveLength(43);
    expect(nonce).toHaveLength(43);
    expect(pairingToken).toHaveLength(43);
  });

  it("access key", async () => {
    expect(hex(await accessKeyFor(pairingToken))).toBe(expected.accessKey);
  });

  it("phone proof, accepted by the relay's own check", async () => {
    const accessKey = b64url(fromHex(expected.accessKey));
    const made = await proof(accessKey, mailboxID, nonce);
    expect(hex(fromB64url(made)!)).toBe(expected.phoneProof);
    expect(await verifyPhone(accessKey, b64url(fromHex(expected.phoneProof)), mailboxID, nonce)).toBe(true);
    // A proof for another nonce is refused.
    expect(await verifyPhone(accessKey, made, mailboxID, b64url(counting(33)))).toBe(false);
  });

  it("host signature over the payload, accepted by the relay's own check", async () => {
    const key = await hostKeyFromSeed(hostSeed);
    const jwk = (await crypto.subtle.exportKey("jwk", key)) as JsonWebKey;
    const publicKey = fromB64url(jwk.x!)!;
    expect(hex(publicKey)).toBe(expected.hostPublicKey);

    const payload = enc.encode(`ensemble-relay-host|${mailboxID}|${nonce}`);
    const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", key, payload));
    expect(hex(sig)).toBe(expected.hostSignature);

    const pub = b64url(publicKey);
    expect(await verifyHost(pub, b64url(sig), mailboxID, nonce)).toBe(true);
    // The payload binds the mailbox and the nonce.
    expect(await verifyHost(pub, b64url(sig), b64url(counting(1)), nonce)).toBe(false);
    expect(await verifyHost(pub, b64url(sig), mailboxID, b64url(counting(33)))).toBe(false);
  });
});
