# Analysis of the four prior `sample` files committed by lanes impl-915 / impl-917 / impl-918 / impl-919

Produced by impl-956 (2026-09-19) with a stdlib-only parser over the committed
gzipped samples. Only measurements are listed; conclusions live in `.report-1.md`.

## 1. `impl-915/just-fast-attempt1-sample.txt.gz` — the DRIVER, not the test process

- `Process: swift-package [14246]`, `Parent Process: just [14188]`. ("swift-package"
  is the SwiftPM `swift-test` driver binary; argv[0] is `swift-test`.)
- 4 threads total; every thread is idle:
  - main thread: `CFRunLoopRun` → `__CFRunLoopServiceMachPort` → `mach_msg2_trap` (idle run loop);
  - one cooperative-pool thread: `_dispatch_group_wait_slow` → `_dlock_wait` → `__ulock_wait`;
  - two `libSwiftToolsSupport` threads: `__NSThread__start__` → `libSwiftToolsSupport` → `read` (libsystem_kernel) — the child-process stdout/stderr pipe readers.
- Read: the driver is waiting for a child process while draining its output pipe.
  The stack does **not** show an SPM file lock, a package-resolution path, or any
  "Another instance of SwiftPM is already running" state.
- Identity of the child (which test process, which test) is **not** in this sample.

## 2. `impl-918/core-idle-hang-sample.txt.gz` — the RUNNER, parked in XCTest's async waiter

- `Process: xctest [76729]`, `Parent Process: swift-package [76250]`; launch 14:15:22, sample 14:20:20 (≈ 5 min frozen).
- 3 threads; the only non-idle stack is the main thread (1031/1031 samples):
  `-[XCTestCase invokeTestMethod:]` → `+[XCTFailableInvocation invokeWithAsynchronousWait:…]`
  → `+[XCTWaiter waitForExpectations:timeout:enforceOrder:]` → `-[XCTWaiter _performWait:…]`
  → `+[XCTWaiter _synchronouslyWaitForTimeInterval:]` → `CFRunLoopRunSpecific`
  → `__CFRunLoopServiceMachPort` → `mach_msg2_trap` (0 % CPU).
- No Sendmeter / SendmeterCoreTests frame appears on any thread (`[Sendmeter]` also
  matches the binary-image list only).
- Read: an **async test whose awaited continuation never resumes** — XCTest's
  per-test async bridge sits in its run loop; nothing in the product is running.

## 3. `impl-919/core-idle-hang-sample.txt.gz` — same shape as (2)

- `Process: xctest [61419]`, `Parent Process: swift-package [57514]`; launch 20:45:56, sample 20:58:10 (≈ 12 min frozen), 1844/1844 samples in the same XCTWaiter chain.

## 4. `impl-917/build-ios-hang-sample.txt.gz` — a different class: the Xcode build

- `Process: xcodebuild [24552]`, `Parent Process: bash [24551]` — the pinned/unattached
  `/Volumes/NVMe2TB` DerivedData class; unrelated to the suite hangs.
