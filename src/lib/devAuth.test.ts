import type { Session } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import {
  autoSignInForLocalDev,
  LOCAL_DEV_EMAIL,
  LOCAL_DEV_PASSWORD,
  shouldAutoSignInForLocalDev,
} from "./devAuth";

describe("shouldAutoSignInForLocalDev", () => {
  it("allows the generated flag against the local Supabase stack", () => {
    expect(
      shouldAutoSignInForLocalDev({
        enabled: "true",
        supabaseUrl: "http://127.0.0.1:54321",
        pageSearch: "",
      }),
    ).toBe(true);
  });

  it("never auto-signs into a hosted project", () => {
    expect(
      shouldAutoSignInForLocalDev({
        enabled: "true",
        supabaseUrl: "https://zznsqmcewtzlnfoiefkk.supabase.co",
        pageSearch: "",
      }),
    ).toBe(false);
  });

  it.each([
    { enabled: undefined, pageSearch: "" },
    { enabled: "false", pageSearch: "" },
    { enabled: "true", pageSearch: "?auth" },
    { enabled: "true", pageSearch: "?auth=false" },
  ])("supports disabled and explicit auth-screen flows: %o", (input) => {
    expect(
      shouldAutoSignInForLocalDev({
        ...input,
        supabaseUrl: "http://localhost:54321",
      }),
    ).toBe(false);
  });

  it("fails closed for malformed URLs and lookalike hosts", () => {
    for (const supabaseUrl of [
      "not a URL",
      "https://127.0.0.1:54321",
      "http://127.0.0.1.example.com:54321",
    ]) {
      expect(
        shouldAutoSignInForLocalDev({
          enabled: "true",
          supabaseUrl,
          pageSearch: "",
        }),
      ).toBe(false);
    }
  });
});

describe("autoSignInForLocalDev", () => {
  it("uses the seeded account and deduplicates concurrent launches", async () => {
    let resolve!: (value: {
      data: { session: Session | null };
      error: Error | null;
    }) => void;
    const signInWithPassword = vi.fn(
      () =>
        new Promise<{
          data: { session: Session | null };
          error: Error | null;
        }>((done) => {
          resolve = done;
        }),
    );
    const auth = { signInWithPassword };

    const first = autoSignInForLocalDev(auth);
    const second = autoSignInForLocalDev(auth);
    expect(first).toBe(second);
    expect(signInWithPassword).toHaveBeenCalledOnce();
    expect(signInWithPassword).toHaveBeenCalledWith({
      email: LOCAL_DEV_EMAIL,
      password: LOCAL_DEV_PASSWORD,
    });

    resolve({ data: { session: null }, error: null });
    await expect(first).resolves.toBeNull();
  });

  it("allows a retry after an unsuccessful attempt", async () => {
    const auth = {
      signInWithPassword: vi
        .fn()
        .mockResolvedValueOnce({
          data: { session: null },
          error: new Error("local stack unavailable"),
        })
        .mockResolvedValueOnce({ data: { session: null }, error: null }),
    };

    await expect(autoSignInForLocalDev(auth)).rejects.toThrow(
      "local stack unavailable",
    );
    await expect(autoSignInForLocalDev(auth)).resolves.toBeNull();
    expect(auth.signInWithPassword).toHaveBeenCalledTimes(2);
  });
});
