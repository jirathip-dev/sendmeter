import { supabase } from "../supabase";
import { unwrap } from "./shared";
import type { AuthEventRow } from "../authEventFlush";

/// Issue #202: the on-device auth-diagnostics ring, pushed on the next
/// successful sign-in. Upsert (not insert) on the `(user_id, reason,
/// first_at)` unique index — the same incident is re-sent every launch with a
/// grown `occurrences`/`last_at`, and must update its row rather than pile up
/// duplicates.
export async function upsertAuthEvents(rows: AuthEventRow[]): Promise<void> {
  unwrap(
    await supabase
      .from("auth_events")
      .upsert(rows, { onConflict: "user_id,reason,first_at" }),
  );
}
