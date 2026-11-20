import { isConnID, isMailboxID } from "./wire";

export { ClaimLimiter } from "./claim-limiter";
export { Mailbox } from "./mailbox";

/** Routes a request to the Durable Object for its mailbox. Anything else is a 404, a non-upgrade is a 426. */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.has("Origin")) return new Response("forbidden", { status: 403 });
    const route = parseRoute(new URL(request.url).pathname);
    if (!route || request.method !== "GET") return new Response("not found", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("upgrade required", { status: 426, headers: { Upgrade: "websocket" } });
    }
    return env.MAILBOX.getByName(route.id).fetch(request);
  },
} satisfies ExportedHandler<Env>;

function parseRoute(path: string): { id: string; role: "host" | "phone" | "data" } | null {
  const parts = path.split("/");
  // ["", "v1", "mailbox", id, role, conn?]
  if (parts[0] !== "" || parts[1] !== "v1" || parts[2] !== "mailbox") return null;
  const id = parts[3];
  if (id === undefined || !isMailboxID(id)) return null;
  const role = parts[4];
  if ((role === "host" || role === "phone") && parts.length === 5) return { id, role };
  if (role === "data" && parts.length === 6 && isConnID(parts[5]!)) return { id, role };
  return null;
}
