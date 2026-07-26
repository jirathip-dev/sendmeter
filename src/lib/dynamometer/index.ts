/// Dynamometer layer entry point (#173) — import from here, not from the
/// individual modules, so driver registration always happens.
///
/// ADDING A DEVICE: write `./<device>.ts` implementing `DynamometerDriver`,
/// import it here, and add one `registerDynamometerDriver(...)` line below.
/// Nothing else in the app should need to change — and
/// `dynamometer.contract.test.ts` will hold the new driver to the same
/// behavioural contract the Tindeq one passes.

import { registerDynamometerDriver } from "./registry";
import { tindeqDriver } from "./tindeq";

registerDynamometerDriver(tindeqDriver);

export * from "./types";
export {
  activeDynamometerDriver,
  getDynamometerDriver,
  listDynamometerDrivers,
  registerDynamometerDriver,
} from "./registry";
export { tindeqDriver, TINDEQ_DRIVER_ID } from "./tindeq";
