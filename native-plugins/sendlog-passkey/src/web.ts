import { WebPlugin } from "@capacitor/core";
import type {
  PasskeyAuthenticateResult,
  PasskeyRegisterResult,
  SendLogPasskeyPlugin,
} from "./definitions";

/// On the web the browser WebAuthn API works directly (origin = sendmeter.app),
/// so the app uses supabase-js's built-in flow and never calls this plugin.
/// These stubs exist only to satisfy the interface.
export class SendLogPasskeyWeb
  extends WebPlugin
  implements SendLogPasskeyPlugin
{
  async isSupported(): Promise<{ supported: boolean }> {
    return { supported: false };
  }

  async register(): Promise<PasskeyRegisterResult> {
    throw this.unimplemented("Use the browser WebAuthn flow on web.");
  }

  async authenticate(): Promise<PasskeyAuthenticateResult> {
    throw this.unimplemented("Use the browser WebAuthn flow on web.");
  }
}
