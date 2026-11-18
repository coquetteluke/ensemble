// Limits that keep one mailbox, and the relay as a whole, inside the Workers free plan.

/** Connections from one address that have not yet proved the access key. */
export const MAX_UNPROVEN_PER_ADDRESS = 3;
/** Addresses remembered for bad handshakes at once. */
export const MAX_TRACKED_ADDRESSES = 256;

/** Phones that may be waiting or paired at once for one Mac. */
export const MAX_PHONES = 8;
/** Phones that may be waiting for their data socket at once. */
export const MAX_WAITING = 3;

/** A host or phone must answer the challenge within this long. */
export const CHALLENGE_TIMEOUT_MS = 10_000;
/** A waiting phone must be paired, and a data socket must send its token, within this long. */
export const PAIR_TIMEOUT_MS = 15_000;

/** Incoming messages (phone and Mac data sockets together) per mailbox per UTC day. */
export const DAILY_MESSAGES = 40_000;
/** Incoming bytes per mailbox per UTC day. */
export const DAILY_BYTES = 200 * 1024 * 1024;
/** The counters reach storage at most this often. */
export const BUDGET_FLUSH_MS = 60_000;

/** Bad handshakes reported by the Mac from one address before that address is blocked. */
export const FAILURES_BEFORE_BLOCK = 5;
export const BLOCK_MS = 15 * 60 * 1000;

/** A mailbox whose Mac has not signed in for this long is deleted. */
export const IDLE_DELETE_MS = 90 * 24 * 3600 * 1000;

/** First claims per address per hour. */
export const CLAIMS_PER_IP_PER_HOUR = 10;
export const CLAIM_WINDOW_MS = 3600 * 1000;
