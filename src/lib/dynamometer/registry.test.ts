import { beforeEach, describe, expect, it } from "vitest";
import {
  activeDynamometerDriver,
  getDynamometerDriver,
  listDynamometerDrivers,
  registerDynamometerDriver,
  resetDynamometerRegistry,
} from "./registry";
import type { DynamometerDriver } from "./types";

function stub(id: string): DynamometerDriver {
  return {
    id,
    deviceName: id,
    capabilities: { tare: false, lowBatteryWarning: false, deviceInfo: false },
    availability: () => ({ supported: false, secure: true }),
    connect: () => Promise.reject(new Error("not connectable")),
  };
}

// Deliberately imports `./registry` and NOT `./index`, so these run against an
// empty registry rather than the app's real (Tindeq-registered) one.
describe("dynamometer registry", () => {
  beforeEach(() => resetDynamometerRegistry());

  it("looks a driver up by id and returns null for an unknown one", () => {
    const a = stub("a");
    registerDynamometerDriver(a);
    expect(getDynamometerDriver("a")).toBe(a);
    expect(getDynamometerDriver("nope")).toBe(null);
  });

  it("lists drivers in registration order", () => {
    registerDynamometerDriver(stub("a"));
    registerDynamometerDriver(stub("b"));
    expect(listDynamometerDrivers().map((d) => d.id)).toEqual(["a", "b"]);
  });

  it("tolerates the same driver being registered twice (HMR re-executes modules)", () => {
    const a = stub("a");
    registerDynamometerDriver(a);
    expect(() => registerDynamometerDriver(a)).not.toThrow();
    expect(listDynamometerDrivers()).toHaveLength(1);
  });

  it("rejects two different drivers claiming one id", () => {
    registerDynamometerDriver(stub("a"));
    expect(() => registerDynamometerDriver(stub("a"))).toThrow(/already registered/);
  });

  it("resolves the active driver to the first registered one", () => {
    registerDynamometerDriver(stub("a"));
    registerDynamometerDriver(stub("b"));
    expect(activeDynamometerDriver().id).toBe("a");
  });

  it("throws rather than returning undefined when nothing is registered", () => {
    expect(() => activeDynamometerDriver()).toThrow(/No dynamometer driver/);
  });
});
