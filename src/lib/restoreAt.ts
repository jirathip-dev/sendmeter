/// Re-insert an optimistically-removed item back into a list, e.g. rolling
/// back an optimistic delete after the server call fails (issue #166).
/// Puts `item` back at `index` (clamped to the list's current length, in case
/// other items were removed/added meanwhile) and is a no-op if an item with
/// the same id is already present, so a duplicate re-insert (e.g. a second
/// failed attempt racing the first) can't create a dupe row.
export function restoreAt<T extends { id: string }>(
  list: T[],
  item: T,
  index: number,
): T[] {
  if (list.some((x) => x.id === item.id)) return list;
  const next = [...list];
  next.splice(Math.min(index, next.length), 0, item);
  return next;
}
