import { Capacitor } from "@capacitor/core";

/// Custom URL scheme the native app registers (Info.plist CFBundleURLTypes) and
/// that Supabase must allow-list as a redirect URL.
export const AUTH_SCHEME = "com.jirathip.sendlog";

/// Where an auth email (magic link, password reset) should send the user back:
/// into the native app via its scheme, or the current web origin. This is what
/// makes a link *started on the app* reopen the app, and one started on the web
/// stay on the web (SL-29).
export function authRedirectUrl(): string {
  return Capacitor.isNativePlatform()
    ? `${AUTH_SCHEME}://auth`
    : window.location.origin;
}
