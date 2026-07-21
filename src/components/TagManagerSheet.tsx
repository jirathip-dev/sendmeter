import { useState } from "react";
import { useRealtimeBump } from "../hooks/useRealtimeVersion";
import { useToast } from "../hooks/useToast";
import { renameTag, setTagHidden } from "../lib/repo";
import Sheet from "./Sheet";

interface TagInfo {
  name: string;
  count: number;
}

interface Props {
  /// Every tag with recordings (name + rep count), plus which are hidden.
  tags: TagInfo[];
  hidden: Set<string>;
  onClose: () => void;
}

/// Manage the exercise tags (SL-92): rename one across the whole dataset —
/// every recording carrying it follows — or hide it from the Force-tab
/// pickers/trend without deleting anything. Renaming into an existing tag
/// merges the two.
export default function TagManagerSheet({ tags, hidden, onClose }: Props) {
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
      toast(merged ? `Merged into “${next}”` : `Renamed to “${next}”`, "success");
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

  const sorted = [...tags].sort((a, b) => a.name.localeCompare(b.name));

  return (
    <Sheet onClose={onClose}>
      <div
        style={{
          fontFamily: "Inter, sans-serif",
          fontSize: "var(--t-xl)",
          fontWeight: 800,
          marginBottom: 2,
        }}
      >
        Manage tags
      </div>
      <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-muted)", marginBottom: 12 }}>
        Rename updates every recording with that tag. Hiding keeps the data but
        drops the tag from the pickers and trend.
      </div>

      {sorted.length === 0 && (
        <div style={{ fontSize: "var(--t-sm)", color: "var(--ink-faint)", padding: "12px 0" }}>
          No tags yet — record a rep with a tag first.
        </div>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {sorted.map((t) => {
          const isHidden = hidden.has(t.name);
          const isEditing = editing === t.name;
          return (
            <div
              key={t.name}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                padding: "8px 10px",
                borderRadius: 9,
                border: "1px solid var(--border)",
                background: "var(--surface-1)",
                opacity: isHidden && !isEditing ? 0.55 : 1,
              }}
            >
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
                    style={{ width: "auto", flexShrink: 0, padding: "0 14px" }}
                    disabled={busy || !draft.trim()}
                    onClick={() => void commitRename(t.name)}
                  >
                    Save
                  </button>
                  <button
                    onClick={() => setEditing(null)}
                    style={pillBtn}
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
                      <span style={{ color: "var(--ink-faint)", fontWeight: 500 }}> · hidden</span>
                    )}
                  </span>
                  <span style={{ fontSize: "var(--t-2xs)", color: "var(--ink-muted)" }}>
                    {t.count} rep{t.count === 1 ? "" : "s"}
                  </span>
                  <button
                    onClick={() => {
                      setDraft(t.name);
                      setEditing(t.name);
                    }}
                    style={pillBtn}
                    aria-label={`Rename ${t.name}`}
                    disabled={busy}
                  >
                    ✎
                  </button>
                  <button
                    onClick={() => void toggleHidden(t.name, !isHidden)}
                    style={pillBtn}
                    aria-label={isHidden ? `Show ${t.name}` : `Hide ${t.name}`}
                    disabled={busy}
                  >
                    {isHidden ? "Show" : "Hide"}
                  </button>
                </>
              )}
            </div>
          );
        })}
      </div>

      <div style={{ marginTop: 14 }}>
        <button className="btn-ghost" onClick={onClose}>
          Done
        </button>
      </div>
    </Sheet>
  );
}

const pillBtn: React.CSSProperties = {
  flexShrink: 0,
  background: "none",
  border: "1px solid var(--border)",
  color: "var(--ink-muted)",
  padding: "5px 9px",
  borderRadius: 7,
  fontSize: "var(--t-2xs)",
  fontFamily: "Inter, sans-serif",
  cursor: "pointer",
};
