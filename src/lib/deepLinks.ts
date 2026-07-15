import { App } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";
import { supabase } from "./supabase";

/// Native only: complete an auth email flow that redirected back into the app
/// via the custom scheme (com.jirathip.sendlog://auth#access_token=...&type=…).
/// The WebView's own page URL never carries these tokens — they arrive through
/// the appUrlOpen deep link — so supabase-js can't auto-detect them; we parse
/// the link and set the session by hand (SL-29).
export function initDeepLinks(): void {
  if (!Capacitor.isNativePlatform()) return;
  void App.addListener("appUrlOpen", ({ url }) => {
    const hash = url.includes("#") ? url.slice(url.indexOf("#") + 1) : "";
    if (!hash) return;
    const params = new URLSearchParams(hash);
    const access_token = params.get("access_token");
    const refresh_token = params.get("refresh_token");
    if (!access_token || !refresh_token) return;
    void supabase.auth
      .setSession({ access_token, refresh_token })
      .then(() => {
        // A password-reset link asks for a new password before entering the app;
        // setSession fires SIGNED_IN, not PASSWORD_RECOVERY, so signal it here.
        if (params.get("type") === "recovery") {
          window.dispatchEvent(new CustomEvent("sendmeter:recovery"));
        }
      })
      .catch(() => {
        /* malformed / expired link — user can retry from the login screen */
      });
  });
}
