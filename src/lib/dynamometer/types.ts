/// The device-agnostic dynamometer contract (#173).
///
/// Everything above this line — `useTindeq`, ForceView, the guided protocol
/// engine — deals in force samples and a small command set. Everything below
/// it (a *driver*) deals in one manufacturer's transport, packet format and
/// command bytes. Adding a second dynamometer should mean writing a driver and
/// registering it, not editing the hook.
///
/// HONESTY NOTE: there is exactly ONE driver today (Tindeq Progressor over
/// BLE), so this interface is inevitably shaped by it. It was drawn from what
/// the *consumer* already needed rather than from what a hypothetical device
/// might offer, and speculative hooks were deliberately left out: no unit
/// negotiation (everything here is kgf, which is what the DB stores), no
/// sample-rate control, no battery percentage, no firmware/serial reporting,
/// no multi-device pairing. Add those when a real second device demands them —
/// each would otherwise be a guess dressed up as a contract.

/** One force reading exactly as the device reported it. */
export interface ForceSample {
  /// Device-clock timestamp in MICROseconds. The epoch is the device's own
  /// (Tindeq counts from power-on), so it is only meaningful as a difference:
  /// the consumer subtracts the first sample of the current recording. A
  /// driver whose device has no clock of its own must synthesize this from the
  /// host clock rather than leave it out.
  us: number;
  /// Force in kilograms-force. The whole app (charts, DB, protocol targets)
  /// stores kg, so unit conversion is the driver's job, not the consumer's.
  kg: number;
}

/// What a driver can and cannot do. This is how a device reports capabilities
/// it *lacks*: the flag reads false, the corresponding method is a resolved
/// no-op (never a throw — a consumer must not have to try/catch to discover
/// what's missing), and consumers gate optional UI on the flag.
export interface DynamometerCapabilities {
  /// `tare()` zeroes the load cell. false ⇒ tare() is a no-op and the UI
  /// should hide the control rather than offer a button that does nothing.
  tare: boolean;
  /// The device pushes an unsolicited low-battery warning, surfaced as
  /// `onLowBattery`. false ⇒ that callback never fires. Deliberately a
  /// boolean, not a percentage: the Progressor only reports "low", and
  /// inventing a percentage field no device here can fill would be fiction.
  lowBatteryWarning: boolean;
  /// `refreshDeviceInfo()` actually asks the device for something. false ⇒
  /// it's a no-op.
  deviceInfo: boolean;
}

/// Pushed events from a connected device. Supplied once at connect time —
/// there is only ever one consumer (the hook), so a full event-emitter would
/// be ceremony.
export interface DynamometerListener {
  /// A batch of readings. Drivers deliver whatever the transport gave them
  /// (the Progressor packs several samples per BLE notification); consumers
  /// must not assume one sample per call.
  onSamples(samples: ForceSample[]): void;
  /// The device says its battery is low. Only fires when
  /// `capabilities.lowBatteryWarning`.
  onLowBattery(): void;
  /// The link dropped without the consumer asking — out of range, powered
  /// off, OS-level disconnect. NOT called for a consumer-initiated
  /// `disconnect()`; that path is synchronous from the consumer's point of
  /// view and it already knows.
  onDisconnected(): void;
}

/// A live connection to one device. Every method is safe to call at any time
/// after connect: the consumer owns the measuring state machine, and a driver
/// must not enforce its own ordering rules on top.
export interface DynamometerConnection {
  /// The driver that produced this connection.
  readonly driverId: string;
  /// Begin streaming samples to `onSamples`.
  startMeasuring(): Promise<void>;
  /// Stop streaming. May reject if the device is already gone; the consumer
  /// treats that as benign (the samples it already has are still valid).
  stopMeasuring(): Promise<void>;
  /// Zero the load cell. No-op when `capabilities.tare` is false.
  tare(): Promise<void>;
  /// Ask the device to report status it doesn't push on its own. Anything it
  /// answers with arrives through the listener (for the Progressor: a
  /// low-battery push). No-op when `capabilities.deviceInfo` is false.
  refreshDeviceInfo(): Promise<void>;
  /// Consumer-initiated teardown. Does not fire `onDisconnected`.
  disconnect(): Promise<void>;
}

/// Whether this driver can run in the current environment at all. Split in two
/// because the UI says different things for "wrong browser" and "not HTTPS".
export interface DynamometerAvailability {
  /// The transport exists here (native BLE, or a browser with Web Bluetooth).
  supported: boolean;
  /// The page context permits the transport. Web Bluetooth needs a secure
  /// context; a driver with no such requirement returns true.
  secure: boolean;
}

export interface DynamometerDriver {
  /// Stable identifier, used by the registry and stored nowhere else yet.
  readonly id: string;
  /// Product name for UI copy ("Tindeq Progressor"). The Force tab's copy is
  /// still hardcoded — see the comments there — so nothing reads this yet;
  /// it's the hook-side handle for whoever does that pass.
  readonly deviceName: string;
  readonly capabilities: DynamometerCapabilities;
  /// Cheap and synchronous — the hook calls it once at module load to decide
  /// whether to render the "Bluetooth not available" card.
  availability(): DynamometerAvailability;
  /// Pair (prompting the user if the platform requires it) and connect.
  /// Rejects with `DynamometerCancelledError` when the user dismisses the
  /// picker; any other rejection is a real failure whose message is shown.
  connect(listener: DynamometerListener): Promise<DynamometerConnection>;
}

/// The user backed out of the device picker. Not an error worth showing —
/// every driver has to be able to say "nothing went wrong, they just didn't
/// pick a device", and the platform-specific shape of that (a Web Bluetooth
/// `NotFoundError` DOMException here) must not leak to the consumer.
export class DynamometerCancelledError extends Error {
  constructor(message = "Device selection cancelled") {
    super(message);
    this.name = "DynamometerCancelledError";
  }
}
