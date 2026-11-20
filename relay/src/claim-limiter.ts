import { DurableObject } from "cloudflare:workers";
import { CLAIM_WINDOW_MS, CLAIMS_PER_IP_PER_HOUR } from "./limits";

/**
 * Counts first claims for one source address. The object is named by a hash of the address, never the address.
 * Storage holds only the times of the claims inside the last hour, and an alarm clears it when they are all old.
 */
export class ClaimLimiter extends DurableObject<Env> {
  /** Records one claim. Returns false, and records nothing, when the address has used its claims for the hour. */
  async hit(): Promise<boolean> {
    const now = Date.now();
    const recent = ((await this.ctx.storage.get<number[]>("claims")) ?? []).filter((t) => now - t < CLAIM_WINDOW_MS);
    if (recent.length >= CLAIMS_PER_IP_PER_HOUR) return false;
    recent.push(now);
    await this.ctx.storage.put("claims", recent);
    await this.ctx.storage.setAlarm(recent[0]! + CLAIM_WINDOW_MS);
    return true;
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const recent = ((await this.ctx.storage.get<number[]>("claims")) ?? []).filter((t) => now - t < CLAIM_WINDOW_MS);
    if (recent.length === 0) {
      await this.ctx.storage.deleteAll();
      return;
    }
    await this.ctx.storage.put("claims", recent);
    await this.ctx.storage.setAlarm(recent[0]! + CLAIM_WINDOW_MS);
  }
}
