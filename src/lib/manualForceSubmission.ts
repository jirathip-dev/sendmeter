export function manualAttemptKey(set: number, rep: number, side: string): string {
  return `${set}:${rep}:${side}`;
}

export function claimManualAttempt(
  key: string,
  ids: Map<string, string>,
  claimed: Set<string>,
  makeId: () => string,
): string | null {
  if (claimed.has(key)) return null;
  claimed.add(key);
  const existing = ids.get(key);
  if (existing) return existing;
  const id = makeId();
  ids.set(key, id);
  return id;
}

export function claimManualSession(groupId: string, claimed: Set<string>): boolean {
  if (claimed.has(groupId)) return false;
  claimed.add(groupId);
  return true;
}

export function appendUniqueById<T extends { id: string }>(list: T[], item: T): T[] {
  return list.some((existing) => existing.id === item.id) ? list : [...list, item];
}
