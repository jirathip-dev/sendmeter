/** @vitest-environment jsdom */

import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  createThemeController,
  DARK_COLOR_SCHEME_QUERY,
  DARK_THEME_COLOR,
  LIGHT_COLOR_SCHEME_QUERY,
  LIGHT_THEME_COLOR,
  resolvedTheme,
} from "./theme";

interface FakeMediaQuery {
  media: string;
  matches: boolean;
  addEventListener: (type: string, listener: () => void) => void;
  removeEventListener: (type: string, listener: () => void) => void;
  emit: (matches: boolean) => void;
}

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() {
      return values.size;
    },
    clear() {
      values.clear();
    },
    getItem(key) {
      return values.get(key) ?? null;
    },
    key(index) {
      return Array.from(values.keys())[index] ?? null;
    },
    removeItem(key) {
      values.delete(key);
    },
    setItem(key, value) {
      values.set(key, value);
    },
  };
}

function fakeMediaQuery(matches: boolean): FakeMediaQuery {
  const listeners = new Set<() => void>();
  return {
    media: DARK_COLOR_SCHEME_QUERY,
    matches,
    addEventListener(type, listener) {
      if (type === "change") listeners.add(listener);
    },
    removeEventListener(type, listener) {
      if (type === "change") listeners.delete(listener);
    },
    emit(next) {
      this.matches = next;
      for (const listener of listeners) listener();
    },
  };
}

function themeMetas(): HTMLMetaElement[] {
  return Array.from(
    document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]'),
  );
}

function metaMediaValue(meta: HTMLMetaElement | undefined): string | null {
  return meta?.getAttribute("media") ?? null;
}

function setup(prefersDark: boolean) {
  document.documentElement.removeAttribute("data-theme");
  document.head.innerHTML = `
    <meta name="theme-color" media="${LIGHT_COLOR_SCHEME_QUERY}" content="${LIGHT_THEME_COLOR}">
    <meta name="theme-color" media="${DARK_COLOR_SCHEME_QUERY}" content="${DARK_THEME_COLOR}">
  `;
  const storage = memoryStorage();
  const media = fakeMediaQuery(prefersDark);
  const controller = createThemeController({
    document,
    storage,
    matchMedia: () => media as unknown as MediaQueryList,
  });
  return { controller, media, storage };
}

describe("theme controller", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("applies explicit Light chrome even when the OS is dark", () => {
    const { controller, storage } = setup(true);
    storage.setItem("theme", "light");

    expect(controller.initialize()).toBe("light");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(resolvedTheme("light", true)).toBe("light");

    const [light, dark] = themeMetas();
    expect(metaMediaValue(light)).toBeNull();
    expect(light?.content).toBe(LIGHT_THEME_COLOR);
    expect(metaMediaValue(dark)).toBe("not all");
    expect(dark?.content).toBe(DARK_THEME_COLOR);
    controller.dispose();
  });

  it("applies explicit Dark chrome even when the OS is light", () => {
    const { controller } = setup(false);
    controller.initialize();
    controller.setChoice("dark");

    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(resolvedTheme("dark", false)).toBe("dark");
    const [light, dark] = themeMetas();
    expect(metaMediaValue(light)).toBe("not all");
    expect(metaMediaValue(dark)).toBeNull();
    expect(dark?.content).toBe(DARK_THEME_COLOR);
    controller.dispose();
  });

  it("restores responsive media-qualified chrome for System and live changes", () => {
    const { controller, media, storage } = setup(true);
    expect(controller.initialize()).toBe("system");
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);

    let [light, dark] = themeMetas();
    expect(metaMediaValue(light)).toBe(LIGHT_COLOR_SCHEME_QUERY);
    expect(metaMediaValue(dark)).toBe(DARK_COLOR_SCHEME_QUERY);
    expect(resolvedTheme("system", media.matches)).toBe("dark");

    media.emit(false);
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
    expect(resolvedTheme("system", media.matches)).toBe("light");

    controller.setChoice("light");
    controller.setChoice("system");
    [light, dark] = themeMetas();
    expect(metaMediaValue(light)).toBe(LIGHT_COLOR_SCHEME_QUERY);
    expect(metaMediaValue(dark)).toBe(DARK_COLOR_SCHEME_QUERY);
    expect(storage.getItem("theme")).toBeNull();
    controller.dispose();
  });

  it("removes stale duplicate theme-color metas while synchronizing", () => {
    const { controller } = setup(false);
    const duplicate = document.createElement("meta");
    duplicate.name = "theme-color";
    duplicate.content = "#badbad";
    document.head.append(duplicate);

    controller.initialize();
    expect(themeMetas()).toHaveLength(2);
    expect(themeMetas().map((meta) => meta.content)).toEqual([
      LIGHT_THEME_COLOR,
      DARK_THEME_COLOR,
    ]);
    controller.dispose();
  });
});
