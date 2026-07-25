import { WebPlugin } from "@capacitor/core";
import type { SendLogHealthPlugin } from "./definitions";

/// No HealthKit in a browser — every method is a no-op. The web app clears
/// health_metrics directly via supabase-js (see src/lib/repo.ts) and relies
/// on the device to re-ingest.
export class SendLogHealthWeb extends WebPlugin implements SendLogHealthPlugin {
  async requestAuthorization(): Promise<void> {}
  async setSession(): Promise<void> {}
  async clearSession(): Promise<void> {}
  async syncNow(): Promise<void> {}
  async clearAndResync(): Promise<void> {}
  async startBackgroundSync(): Promise<void> {}
}
