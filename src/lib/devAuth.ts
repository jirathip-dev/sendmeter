import type { Session } from "@supabase/supabase-js";

export const LOCAL_DEV_EMAIL = "dev@sendmeter.test";
export const LOCAL_DEV_PASSWORD = "devpassword";

type LocalDevAuthClient = {
  signInWithPassword(credentials: {
    email: string;
    password: string;
  }): Promise<{
    data: { session: Session | null };
    error: Error | null;
  }>;
};

export function shouldAutoSignInForLocalDev({
  enabled,
  supabaseUrl,
  pageSearch,
}: {
  enabled: string | undefined;
  supabaseUrl: string;
  pageSearch: string;
}): boolean {
  if (enabled !== "true" || new URLSearchParams(pageSearch).has("auth")) {
    return false;
  }

  try {
    const url = new URL(supabaseUrl);
    return (
      url.protocol === "http:" &&
      (url.hostname === "localhost" ||
        url.hostname === "127.0.0.1" ||
        url.hostname === "[::1]")
    );
  } catch {
    return false;
  }
}

// React Strict Mode mounts effects twice in development. Share the in-flight
// request so those mounts cannot issue two password sign-ins for one launch.
let pendingAutoSignIn: Promise<Session | null> | null = null;

export function autoSignInForLocalDev(
  auth: LocalDevAuthClient,
): Promise<Session | null> {
  if (pendingAutoSignIn) return pendingAutoSignIn;

  const attempt = auth
    .signInWithPassword({
      email: LOCAL_DEV_EMAIL,
      password: LOCAL_DEV_PASSWORD,
    })
    .then(({ data, error }) => {
      if (error) throw error;
      return data.session;
    });

  pendingAutoSignIn = attempt;
  void attempt.then(
    () => {
      if (pendingAutoSignIn === attempt) pendingAutoSignIn = null;
    },
    () => {
      if (pendingAutoSignIn === attempt) pendingAutoSignIn = null;
    },
  );
  return attempt;
}

/**
 * Launch helper used by the DEV-only auth boundary. Keep the warning next to
 * the seeded credentials so neither it nor the implementation can leak into
 * a production bundle through the production hook's error path.
 */
export async function autoSignInForLocalDevOrNull(
  auth: LocalDevAuthClient,
): Promise<Session | null> {
  try {
    return await autoSignInForLocalDev(auth);
  } catch (error) {
    console.warn(
      "Local dev auto-login failed; showing the sign-in screen.",
      error,
    );
    return null;
  }
}
