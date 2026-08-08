/** @vitest-environment jsdom */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  createThemeController,
  DARK_COLOR_SCHEME_QUERY,
  LIGHT_COLOR_SCHEME_QUERY,
} from "./theme";

const indexHtml = readFileSync(join(import.meta.dirname, "..", "..", "index.html"), "utf8");
const bootstrap = indexHtml.match(
  /<script\b[^>]*data-theme-bootstrap[^>]*>([\s\S]*?)<\/script>/i,
)?.[1];
if (!bootstrap) throw new Error("index.html is missing the pre-paint theme bootstrap");

function memoryStorage(initial: string | null): Storage {
  const values = new Map<string, string>();
  if (initial !== null) values.set("theme", initial);
  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => Array.from(values.keys())[index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };
}

function resetHead(): void {
  document.documentElement.removeAttribute("data-theme");
  document.head.innerHTML = `
    <meta name="theme-color" media="${LIGHT_COLOR_SCHEME_QUERY}" content="#F2F4F8">
    <meta name="theme-color" media="${DARK_COLOR_SCHEME_QUERY}" content="#0E121B">
  `;
}

function metas(): HTMLMetaElement[] {
  return Array.from(
    document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]'),
  );
}

function media(meta: HTMLMetaElement | undefined): string | null {
  return meta?.getAttribute("media") ?? null;
}

function runBootstrap(stored: string | null, prefersDark: boolean) {
  resetHead();
  const storage = memoryStorage(stored);
  const matchMedia = vi.fn(() => ({ matches: prefersDark }));
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: storage,
  });
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: matchMedia,
  });
  new Function("window", "document", bootstrap!)(window, document);
  return { storage, matchMedia };
}

describe("pre-paint theme bootstrap", () => {
  it("applies stored Light on a dark OS before the external module loads", () => {
    const { storage, matchMedia } = runBootstrap("light", true);
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(matchMedia).not.toHaveBeenCalled();
    const [light, dark] = metas();
    expect(media(light)).toBeNull();
    expect(media(dark)).toBe("not all");

    const controller = createThemeController({
      document,
      storage,
      matchMedia: matchMedia as unknown as (query: string) => MediaQueryList,
    });
    expect(controller.initialize()).toBe("light");
    controller.dispose();
  });

  it("applies stored Dark on a light OS before the external module loads", () => {
    const { storage, matchMedia } = runBootstrap("dark", false);
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(matchMedia).not.toHaveBeenCalled();
    const [light, dark] = metas();
    expect(media(light)).toBe("not all");
    expect(media(dark)).toBeNull();

    const controller = createThemeController({
      document,
      storage,
      matchMedia: matchMedia as unknown as (query: string) => MediaQueryList,
    });
    expect(controller.initialize()).toBe("dark");
    controller.dispose();
  });

  it.each([
    ["missing storage on dark OS", null, true],
    ["System on a light OS", "system", false],
    ["malformed storage on dark OS", "sepia", true],
  ])("resolves %s safely and lets the runtime controller restore System", (_label, stored, prefersDark) => {
    const { storage, matchMedia } = runBootstrap(stored, prefersDark);
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
    expect(matchMedia).toHaveBeenCalledWith(DARK_COLOR_SCHEME_QUERY);

    const [bootstrapLight, bootstrapDark] = metas();
    expect(media(prefersDark ? bootstrapLight : bootstrapDark)).toBe("not all");
    expect(media(prefersDark ? bootstrapDark : bootstrapLight)).toBeNull();

    const controller = createThemeController({
      document,
      storage,
      matchMedia: matchMedia as unknown as (query: string) => MediaQueryList,
    });
    expect(controller.initialize()).toBe("system");
    const [light, dark] = metas();
    expect(media(light)).toBe(LIGHT_COLOR_SCHEME_QUERY);
    expect(media(dark)).toBe(DARK_COLOR_SCHEME_QUERY);
    controller.dispose();
  });

  it("falls back to System when storage and matchMedia APIs throw", () => {
    resetHead();
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get() {
        throw new Error("storage unavailable");
      },
    });
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => {
        throw new Error("media unavailable");
      },
    });

    expect(() => new Function("window", "document", bootstrap)(window, document)).not.toThrow();
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
    expect(media(metas()[0])).toBeNull();
    expect(media(metas()[1])).toBe("not all");
  });
});
