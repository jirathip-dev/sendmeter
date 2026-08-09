/**
 * The app shell deliberately keeps html/body fixed and puts the real scroll
 * viewport on one or more `.content-area` elements. A sheet must lock all of
 * those roots together: locking only the document leaves iOS free to pan the
 * app's nested WebKit scroller behind a portal.
 *
 * This module owns one process-wide reference count because Sheets can nest
 * (for example, a confirmation sheet opened from a detail sheet). The first
 * acquisition snapshots every target's style, class, and scroll position;
 * only the final release restores them.
 */

export const SHEET_SCROLL_LOCK_CLASS = "sheet-scroll-locked";

interface LockedTarget {
  element: HTMLElement;
  styleText: string;
  className: string;
  scrollTop: number;
  scrollLeft: number;
  isContentRoot: boolean;
  onScroll: () => void;
}
let lockCount = 0;
const lockedTargets = new Map<HTMLElement, LockedTarget>();

function scrollRoots(ownerDocument: Document): HTMLElement[] {
  const roots = [
    ownerDocument.documentElement,
    ownerDocument.body,
    ...Array.from(ownerDocument.querySelectorAll<HTMLElement>(".content-area")),
  ];
  return [...new Set(roots.filter((root): root is HTMLElement => Boolean(root)))];
}

function lockTarget(element: HTMLElement, isContentRoot: boolean): void {
  if (lockedTargets.has(element)) return;

  const target: LockedTarget = {
    element,
    styleText: element.style.cssText,
    className: element.className,
    scrollTop: element.scrollTop,
    scrollLeft: element.scrollLeft,
    isContentRoot,
    onScroll: () => {
      // Some WebKit versions can still report a nested scroll while an
      // overflow-hidden element is receiving a rubber-band gesture. Keep the
      // background at exactly the position captured when the sheet opened.
      if (element.scrollTop !== target.scrollTop) element.scrollTop = target.scrollTop;
      if (element.scrollLeft !== target.scrollLeft) element.scrollLeft = target.scrollLeft;
    },
  };
  lockedTargets.set(element, target);

  if (isContentRoot) element.classList.add(SHEET_SCROLL_LOCK_CLASS);
  element.style.overflow = "hidden";
  element.style.overflowX = "hidden";
  element.style.overflowY = "hidden";
  element.style.overscrollBehavior = "none";
  element.style.setProperty("-webkit-overflow-scrolling", "auto");
  element.addEventListener("scroll", target.onScroll, { passive: true });
  target.onScroll();
}

function restoreTarget(target: LockedTarget): void {
  target.element.removeEventListener("scroll", target.onScroll);
  target.element.style.cssText = target.styleText;
  target.element.className = target.className;
  target.element.scrollTop = target.scrollTop;
  target.element.scrollLeft = target.scrollLeft;
}

/**
 * Acquire the app-wide sheet scroll lock. The returned release function is
 * idempotent, which keeps React effect cleanup safe under Strict Mode and
 * protects nested sheets from an early unlock.
 */
export function acquireSheetScrollLock(ownerDocument?: Document): () => void {
  const documentForLock =
    ownerDocument ?? (typeof document === "undefined" ? undefined : document);
  if (!documentForLock) return () => {};

  lockCount += 1;
  const roots = scrollRoots(documentForLock);
  for (const root of roots) {
    lockTarget(root, root.classList.contains("content-area"));
  }

  let released = false;
  return () => {
    if (released) return;
    released = true;
    lockCount = Math.max(0, lockCount - 1);
    if (lockCount !== 0) return;

    for (const target of lockedTargets.values()) restoreTarget(target);
    lockedTargets.clear();
  };
}
