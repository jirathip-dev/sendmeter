/// The one place a dynamometer driver is registered (#173).
///
/// Registration is a side effect of importing `./index`, which is the only
/// module app code should import from. Adding a device = write a driver, add
/// one `registerDynamometerDriver(...)` line there.

import type { DynamometerDriver } from "./types";

const drivers = new Map<string, DynamometerDriver>();

export function registerDynamometerDriver(driver: DynamometerDriver): void {
  const existing = drivers.get(driver.id);
  // Re-registering the SAME object is fine (vite HMR re-executes a module
  // graph); two different drivers claiming one id is a programming error.
  if (existing && existing !== driver) {
    throw new Error(`Dynamometer driver id already registered: ${driver.id}`);
  }
  drivers.set(driver.id, driver);
}

export function getDynamometerDriver(id: string): DynamometerDriver | null {
  return drivers.get(id) ?? null;
}

/// Registration order.
export function listDynamometerDrivers(): DynamometerDriver[] {
  return [...drivers.values()];
}

/// The driver the app talks to.
///
/// With one registered driver "active" is simply "the one", so there is no
/// selection logic to get wrong yet — and inventing a probe-order or a stored
/// user preference for a device nobody owns would be exactly the speculative
/// machinery #173 warns about. When a second driver lands, THIS function is
/// the single place that has to learn how to choose (a user setting, or
/// availability-probe order); nothing else in the app decides.
export function activeDynamometerDriver(): DynamometerDriver {
  const first = drivers.values().next();
  if (first.done) throw new Error("No dynamometer driver registered");
  return first.value;
}

/// Test-only: drop everything so a suite can register its own fakes without
/// leaking into the next test.
export function resetDynamometerRegistry(): void {
  drivers.clear();
}
