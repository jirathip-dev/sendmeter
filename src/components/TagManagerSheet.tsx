import { useState } from "react";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import {
  renameTag,
  setTagHidden,
  setTagSideMode,
  type TagSideMode,
} from "../lib/repo";
import { normalizeSideMode, type ExerciseSideMode } from "../lib/sideMode";
import { SIDE_MODE_OPTIONS } from "../lib/sideModeUi";
import Sheet from "./Sheet";

interface TagInfo {
  name: string;
  count: number;
}

interface Props {
  /// Every tag with recordings (name + rep count), plus which are hidden.
  tags: TagInfo[];
  hidden: Set<string>;
  /// #584: per-exercise side modes from the slice-1 registry — a missing
  /// entry reads as the legacy default (unilateral or bilateral).
  sideModes: TagSideMode[];
  onClose: () => void;
}

/// Manage the exercise tags (SL-92): rename one across the whole dataset —
/// every recording carrying it follows — or hide it from the Force-tab
/// pickers/trend without deleting anything. Renaming into an existing tag
/// merges the two. Side mode (#584) sets which side choices the Force tab
/// offers for the exercise.
export default function TagManagerSheet({
  tags,
  hidden,
  sideModes,
  onClose,
}: Props) {
  const toast = useToast();
  const bump = useRealtimeBump();
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);

  async function commitRename(oldName: string) {
    const next = draft.trim();
    setEditing(null);
    if (!next || next === oldName) return;
    setBusy(true);
    try {
      await renameTag(oldName, next);
      bump(); // recording tags changed → refetch lists/charts
      const merged = tags.some((t) => t.name === next);
      toast(
        merged ? `Merged into “${next}”` : `Renamed to “${next}”`,
        "success",
      );
    } catch (e) {
      toast(e instanceof Error ? e.message : "Rename failed", "error");
    } finally {
      setBusy(false);
    }
  }

  async function toggleHidden(name: string, hide: boolean) {
    setBusy(true);
    try {
      await setTagHidden(name, hide);
      bump(); // hidden set changed → refetch
      toast(hide ? `Hid “${name}”` : `Showing “${name}”`);
    } catch (e) {
      toast(e instanceof Error ? e.message : "Update failed", "error");
    } finally {
      setBusy(false);
    }
  }

  async function commitSideMode(name: string, mode: ExerciseSideMode) {
    setBusy(true);
    try {
      await setTagSideMode(name, mode);
      bump(); // side-mode registry changed → refetch the policy
      const label =
        SIDE_MODE_OPTIONS.find((o) => o.value === mode)?.label ?? mode;
      toast(`Side mode for “${name}” set to ${label}`, "success");
    } catch (e) {
      toast(e instanceof Error ? e.message : "Update failed", "error");
    } finally {
      setBusy(false);
    }
  }

  const sorted = [...tags].sort((a, b) => a.name.localeCompare(b.name));

  return (
    <Sheet title="Manage exercises" onClose={onClose}>
      <div
        style={{
          fontSize: "var(--t-xs)",
          color: "var(--ink-muted)",
          marginBottom: 12,
        }}
      >
        Rename updates every recording with that exercise. Hiding keeps the data
        but drops the exercise from the pickers and trend. Side mode sets which
        side choices the Force tab offers for it.
      </div>

      {sorted.length === 0 && (
        <div
          style={{
            fontSize: "var(--t-sm)",
            color: "var(--ink-faint)",
            padding: "12px 0",
          }}
        >
          No exercises yet — record a rep with an exercise first.
        </div>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {sorted.map((t) => {
          const isHidden = hidden.has(t.name);
          const isEditing = editing === t.name;
          const mode = normalizeSideMode(
            sideModes.find((m) => m.name === t.name)?.sideMode ?? null,
          );
          return (
            <div
              key={t.name}
              style={{
                display: "flex",
                flexDirection: "column",
                gap: 8,
                padding: "8px 10px",
                borderRadius: 9,
                border: "1px solid var(--border)",
                background: "var(--surface-1)",
                opacity: isHidden && !isEditing ? 0.55 : 1,
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                {isEditing ? (
                  <>
                    <input
                      className="field"
                      autoFocus
                      value={draft}
                      onChange={(e) => setDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") void commitRename(t.name);
                        if (e.key === "Escape") setEditing(null);
                      }}
                      style={{ flex: 1, minWidth: 0, margin: 0 }}
                    />
                    <button
                      className="btn-primary"
                      style={{
                        width: "auto",
                        flexShrink: 0,
                        padding: "0 14px",
                      }}
                      disabled={busy || !draft.trim()}
                      onClick={() => void commitRename(t.name)}
                    >
                      Save
                    </button>
                    <button
                      className="tag-action-button"
                      onClick={() => setEditing(null)}
                      aria-label="Cancel"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <>
                    <span
                      style={{
                        flex: 1,
                        minWidth: 0,
                        fontSize: "var(--t-base)",
                        fontWeight: 700,
                        color: "var(--ink)",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {t.name}
                      {isHidden && (
                        <span
                          style={{ color: "var(--ink-faint)", fontWeight: 500 }}
                        >
                          {" "}
                          · hidden
                        </span>
                      )}
                    </span>
                    <span
                      style={{
                        fontSize: "var(--t-2xs)",
                        color: "var(--ink-muted)",
                      }}
                    >
                      {t.count} rep{t.count === 1 ? "" : "s"}
                    </span>
                    <button
                      className="tag-action-button"
                      onClick={() => {
                        setDraft(t.name);
                        setEditing(t.name);
                      }}
                      aria-label={`Rename ${t.name}`}
                      disabled={busy}
                    >
                      ✎
                    </button>
                    <button
                      className="tag-action-button"
                      onClick={() => void toggleHidden(t.name, !isHidden)}
                      aria-label={
                        isHidden ? `Show ${t.name}` : `Hide ${t.name}`
                      }
                      disabled={busy}
                    >
                      {isHidden ? "Show" : "Hide"}
                    </button>
                  </>
                )}
              </div>
              {!isEditing && (
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span
                    style={{
                      fontSize: "var(--t-2xs)",
                      color: "var(--ink-muted)",
                      flexShrink: 0,
                      textTransform: "uppercase",
                      letterSpacing: "0.04em",
                    }}
                  >
                    Side mode
                  </span>
                  <select
                    className="field"
                    value={mode}
                    disabled={busy}
                    onChange={(e) =>
                      void commitSideMode(
                        t.name,
                        e.target.value as ExerciseSideMode,
                      )
                    }
                    style={{
                      flex: 1,
                      minWidth: 0,
                      margin: 0,
                      padding: "6px 8px",
                      fontSize: "var(--t-xs)",
                    }}
                    aria-label={`Side mode for ${t.name}`}
                  >
                    {SIDE_MODE_OPTIONS.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </Sheet>
  );
}
