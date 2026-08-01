import { supabase } from "../supabase";
import { unwrapOneMutation } from "../mutationInvariant";

/// Throws on a Postgrest error, otherwise returns `data`. Safe for any
/// query except `.maybeSingle()`, where `data: null` with no error is a
/// legitimate "no row" result rather than something this cast should paper
/// over — those call sites keep their own explicit error check.
export function unwrap<T>(result: {
  data: T | null;
  error: { message: string } | null;
}): T {
  if (result.error) throw result.error;
  return result.data as T;
}

/// Factory for the soft-delete/restore/purge triplet shared by `sessions`
/// and `tindeq_recordings` — both tables follow the same `deleted_at`
/// convention (see the soft_delete migration).
export function makeSoftDeleteOps(table: "sessions" | "tindeq_recordings") {
  return {
    /// Soft delete: sets deleted_at so the row can be recovered from Trash.
    async remove(id: string): Promise<void> {
      unwrapOneMutation(
        await supabase
          .from(table)
          .update({ deleted_at: new Date().toISOString() })
          .eq("id", id)
          .select("id")
          .maybeSingle(),
      );
    },
    async restore(id: string): Promise<void> {
      unwrapOneMutation(
        await supabase
          .from(table)
          .update({ deleted_at: null })
          .eq("id", id)
          .select("id")
          .maybeSingle(),
      );
    },
    /// Permanent delete — used only from the Trash view's "Delete forever".
    async purge(id: string): Promise<void> {
      unwrapOneMutation(
        await supabase
          .from(table)
          .delete()
          .eq("id", id)
          .select("id")
          .maybeSingle(),
      );
    },
  };
}
