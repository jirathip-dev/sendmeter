export const THEME_STORAGE_KEY = "theme";
export const LIGHT_THEME_COLOR = "#F2F4F8";
export const DARK_THEME_COLOR = "#0E121B";

export const LIGHT_COLOR_SCHEME_QUERY = "(prefers-color-scheme: light)";
export const DARK_COLOR_SCHEME_QUERY = "(prefers-color-scheme: dark)";

export type ThemeChoice = "system" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

interface ThemeEnvironment {
  document: Document;
  storage?: Storage | null;
  matchMedia?: (query: string) => MediaQueryList;
}

export interface ThemeController {
  initialize(): ThemeChoice;
  setChoice(choice: ThemeChoice): void;
  getChoice(): ThemeChoice;
  dispose(): void;
}

function storageValue(storage: Storage | null | undefined): string | null {
  try {
    return storage?.getItem(THEME_STORAGE_KEY) ?? null;
  } catch {
    // Safari private browsing can expose localStorage and still throw on
    // access. Theme selection should always fall back to system in that case.
    return null;
  }
}

function writeStorage(storage: Storage | null | undefined, choice: ThemeChoice): void {
  try {
    if (choice === "system") storage?.removeItem(THEME_STORAGE_KEY);
    else storage?.setItem(THEME_STORAGE_KEY, choice);
  } catch {
    // A non-persistent theme is still preferable to a broken appearance pane.
  }
}

export function normalizeThemeChoice(value: string | null | undefined): ThemeChoice {
  return value === "light" || value === "dark" ? value : "system";
}

export function resolvedTheme(choice: ThemeChoice, prefersDark: boolean): ResolvedTheme {
  if (choice === "dark") return "dark";
  if (choice === "light") return "light";
  return prefersDark ? "dark" : "light";
}

function setThemeAttribute(document: Document, choice: ThemeChoice): void {
  if (choice === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = choice;
}

function createThemeMeta(document: Document): HTMLMetaElement {
  const meta = document.createElement("meta");
  meta.name = "theme-color";
  document.head.append(meta);
  return meta;
}

function metaMedia(meta: HTMLMetaElement): string {
  return meta.getAttribute("media") ?? "";
}

function setMetaMedia(meta: HTMLMetaElement, media: string): void {
  if (media) meta.setAttribute("media", media);
  else meta.removeAttribute("media");
}

function findThemeMetas(document: Document): [HTMLMetaElement, HTMLMetaElement] {
  const metas = Array.from(
    document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]'),
  );
  const light =
    metas.find((meta) => metaMedia(meta).trim() === LIGHT_COLOR_SCHEME_QUERY) ??
    metas[0] ??
    createThemeMeta(document);
  const dark =
    metas.find(
      (meta) => meta !== light && metaMedia(meta).trim() === DARK_COLOR_SCHEME_QUERY,
    ) ??
    metas.find((meta) => meta !== light) ??
    createThemeMeta(document);

  // There should be exactly one active candidate for each browser scheme.
  // Remove stale duplicates left by older builds rather than letting browser
  // selection order decide which chrome color wins.
  for (const meta of metas) {
    if (meta !== light && meta !== dark) meta.remove();
  }
  return [light, dark];
}

/**
 * Synchronize the browser/PWA chrome with the app's theme choice.
 *
 * System keeps two responsive media-qualified metas. An explicit choice makes
 * exactly one meta active and disables its counterpart with `not all`, which
 * works across Chromium, Safari, and installed PWA shells without relying on
 * querySelector returning a particular media-qualified tag.
 */
export function syncThemeColorMeta(document: Document, choice: ThemeChoice): void {
  const [light, dark] = findThemeMetas(document);
  light.content = LIGHT_THEME_COLOR;
  dark.content = DARK_THEME_COLOR;

  if (choice === "system") {
    setMetaMedia(light, LIGHT_COLOR_SCHEME_QUERY);
    setMetaMedia(dark, DARK_COLOR_SCHEME_QUERY);
  } else if (choice === "light") {
    setMetaMedia(light, "");
    setMetaMedia(dark, "not all");
  } else {
    setMetaMedia(light, "not all");
    setMetaMedia(dark, "");
  }
}

export function createThemeController(environment?: Partial<ThemeEnvironment>): ThemeController {
  const document = environment?.document ?? globalThis.document;
  const storage = environment?.storage ?? globalThis.localStorage;
  const matchMedia =
    environment?.matchMedia ??
    (typeof globalThis.window !== "undefined" &&
    typeof globalThis.window.matchMedia === "function"
      ? globalThis.window.matchMedia.bind(globalThis.window)
      : undefined);

  let choice: ThemeChoice = "system";
  let mediaQuery: MediaQueryList | null = null;
  let mediaListener: (() => void) | null = null;

  function removeSystemListener(): void {
    if (!mediaQuery || !mediaListener) return;
    if (typeof mediaQuery.removeEventListener === "function") {
      mediaQuery.removeEventListener("change", mediaListener);
    } else {
      mediaQuery.removeListener(mediaListener);
    }
    mediaQuery = null;
    mediaListener = null;
  }

  function attachSystemListener(): void {
    removeSystemListener();
    if (choice !== "system" || !matchMedia) return;
    try {
      mediaQuery = matchMedia(DARK_COLOR_SCHEME_QUERY);
      mediaListener = () => {
        // The CSS media-qualified metas are already responsive. Reapplying
        // the DOM state also covers browsers that cache theme-color selection.
        setThemeAttribute(document, choice);
        syncThemeColorMeta(document, choice);
      };
      if (typeof mediaQuery.addEventListener === "function") {
        mediaQuery.addEventListener("change", mediaListener);
      } else {
        mediaQuery.addListener(mediaListener);
      }
    } catch {
      mediaQuery = null;
      mediaListener = null;
    }
  }

  function apply(next: ThemeChoice): void {
    choice = next;
    setThemeAttribute(document, next);
    syncThemeColorMeta(document, next);
    attachSystemListener();
  }

  return {
    initialize() {
      const stored = normalizeThemeChoice(storageValue(storage));
      const fromDom = normalizeThemeChoice(document.documentElement.dataset.theme);
      apply(stored === "system" && fromDom !== "system" ? fromDom : stored);
      return choice;
    },
    setChoice(next) {
      writeStorage(storage, next);
      apply(next);
    },
    getChoice() {
      return choice;
    },
    dispose() {
      removeSystemListener();
    },
  };
}

let defaultController: ThemeController | null = null;

function defaultThemeController(): ThemeController {
  return (defaultController ??= createThemeController());
}

/** Initialize the app theme before React mounts and before the first app paint. */
export function initializeTheme(): ThemeChoice {
  return defaultThemeController().initialize();
}

export function currentThemeChoice(): ThemeChoice {
  return defaultThemeController().getChoice();
}

export function setThemeChoice(choice: ThemeChoice): void {
  defaultThemeController().setChoice(choice);
}
