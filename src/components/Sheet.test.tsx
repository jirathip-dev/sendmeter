// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import Sheet from "./Sheet";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

describe("Sheet", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => {
      root.unmount();
    });
    container.remove();
    document.body.style.overflow = "";
    document.documentElement.style.overflow = "";
  });

  async function render(ui: React.ReactNode) {
    await act(async () => {
      root.render(ui);
      await Promise.resolve();
    });
    // Sheet focuses in a microtask after the portal is attached.
    await act(async () => {
      await Promise.resolve();
    });
    return document.querySelector<HTMLElement>('[role="dialog"]')!;
  }

  it("renders an accessible sticky shell, locks background scroll, and focuses close", async () => {
    const dialog = await render(
      <Sheet title="Session detail" subtitle="Today · 30min" onClose={() => {}}>
        <button type="button">Save</button>
      </Sheet>,
    );

    const title = dialog.querySelector("h2");
    expect(dialog.getAttribute("aria-modal")).toBe("true");
    expect(dialog.getAttribute("aria-labelledby")).toBe(title?.id);
    expect(title?.textContent).toBe("Session detail");
    expect(dialog.querySelector(".modal-top")).toBeTruthy();
    expect(dialog.querySelector(".modal-content")).toBeTruthy();
    expect(dialog.querySelector(".modal-close")).toBeTruthy();
    expect(document.body.style.overflow).toBe("hidden");
    expect(document.documentElement.style.overflow).toBe("hidden");
    expect(document.activeElement).toBe(dialog.querySelector(".modal-close"));
  });

  it("contains Tab focus and lets Escape dismiss the topmost dialog", async () => {
    const onClose = vi.fn();
    const dialog = await render(
      <Sheet title="Focus test" onClose={onClose}>
        <button type="button">First</button>
        <button type="button">Last</button>
      </Sheet>,
    );
    const close = dialog.querySelector<HTMLButtonElement>(".modal-close")!;
    const buttons = [...dialog.querySelectorAll<HTMLButtonElement>("button")];
    const last = buttons[buttons.length - 1]!;

    last.focus();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    expect(document.activeElement).toBe(close);

    close.focus();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true }));
    expect(document.activeElement).toBe(last);

    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("restores the opener and keeps required-choice sheets non-dismissible", async () => {
    const opener = document.createElement("button");
    opener.textContent = "Open";
    document.body.appendChild(opener);
    opener.focus();

    const onClose = vi.fn();
    const dialog = await render(
      <Sheet title="Required choice">
        <button type="button">Keep</button>
      </Sheet>,
    );
    expect(dialog.querySelector(".modal-close")).toBeNull();
    expect(dialog.getAttribute("aria-labelledby")).toBeTruthy();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(onClose).not.toHaveBeenCalled();

    await act(async () => {
      root.unmount();
      await Promise.resolve();
    });
    expect(document.activeElement).toBe(opener);
    opener.remove();
  });

  it("keeps nested sheets stacked and returns focus to the nested opener", async () => {
    function NestedHarness() {
      const [inner, setInner] = useState(false);
      return (
        <Sheet title="Outer" onClose={() => {}}>
          <button type="button" onClick={() => setInner(true)}>
            Open nested
          </button>
          {inner && (
            <Sheet title="Inner" onClose={() => setInner(false)}>
              <button type="button">Inner action</button>
            </Sheet>
          )}
        </Sheet>
      );
    }

    await render(<NestedHarness />);
    const opener = document.querySelector<HTMLButtonElement>("button:not(.modal-close)")!;
    opener.focus();
    await act(async () => {
      opener.click();
      await Promise.resolve();
    });
    expect(document.querySelectorAll('[role="dialog"]')).toHaveLength(2);

    await act(async () => {
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      await Promise.resolve();
    });
    expect(document.querySelectorAll('[role="dialog"]')).toHaveLength(1);
    expect(document.activeElement).toBe(opener);
    expect(document.body.style.overflow).toBe("hidden");
  });
});
