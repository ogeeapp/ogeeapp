import type { Sql } from "postgres";

export const OGEE_EVENTS_CHANNEL = "ogee_events";

export type OgeeEventSummary = Record<string, unknown>;
export type OgeeEventHandler = (event: OgeeEventSummary) => void | Promise<void>;

export async function notifyOgeeEvents(
  sql: Sql,
  event: OgeeEventSummary,
): Promise<void> {
  const payload = JSON.stringify(event, (_key, value: unknown) =>
    typeof value === "bigint" ? value.toString() : value,
  );
  await sql.notify(OGEE_EVENTS_CHANNEL, payload);
}

export async function listenOgeeEvents(
  sql: Sql,
  handler: OgeeEventHandler,
): Promise<() => Promise<void>> {
  const subscription = await sql.listen(OGEE_EVENTS_CHANNEL, (payload) => {
    let event: unknown;
    try {
      event = JSON.parse(payload) as unknown;
    } catch {
      return;
    }
    if (!event || typeof event !== "object" || Array.isArray(event)) return;
    void Promise.resolve(handler(event as OgeeEventSummary)).catch(() => undefined);
  });
  return async () => {
    await subscription.unlisten();
  };
}
