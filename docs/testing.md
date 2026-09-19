# Test and coverage gates

The Swift coverage gate is `bash scripts/swift-coverage.sh`. It runs host-only
tests with `swift test --enable-code-coverage`, merges the fresh profiles with
`llvm-profdata`, and checks `llvm-cov` reports for the three pure-logic
packages. Each package is scoped to its own source tree; tests, build output,
generated resource accessors, and the native app's platform/weather adapter
are excluded. Coverage artifacts are written under the ignored `coverage/`
directory and uploaded by the `Core tests` job in `native-swift.yml`.

The retired root web coverage gate was removed with the web surface (#857 —
`docs/architecture/857-removal-inventory.md`), and there is no root npm package
to run it from.

Baselines were measured on 2026-08-25 from the worktree's complete test
suites. Floors are deliberately a small margin below those measurements and
are not rounded up beyond the captured baseline.

| Surface | Line baseline | Line floor | Function baseline | Function floor |
| --- | ---: | ---: | ---: | ---: |
| `SendmeterCore` | 91.03% (10,738/11,796) | 89% | 85.35% (1,491/1,747) | 83% |
| `SendLogWatchCore` | 95.93% (3,607/3,760) | 94% | 92.79% (592/638) | 91% |
| `SendLogHealthCore` | 98.75% (237/240) | 96% | 94.44% (51/54) | 92% |

For a local check, run:

```bash
bash scripts/test-coverage-threshold.sh
bash scripts/swift-coverage.sh
```

`scripts/test-coverage-threshold.sh` exercises both below-floor failures and
above-floor success for the shared numeric checker
(`scripts/check-coverage-threshold.sh`), which the Swift helper also uses. `Package.resolved` is
backed up and restored by the Swift helper so coverage runs do not commit
SwiftPM's resolution churn. No generated coverage files belong in Git.

## When a host gate hangs or a simulator run fails to launch

A hanging `swift test`, `The test runner hung before establishing connection`, a
`queue never reached …` app-target failure, and the pinned-DerivedData build stall are
host/tooling classes, not test verdicts. The measured signatures, the kill/retry policy
(report both attempts), the buffered-log trap, and the one-run-per-container rule for the
app-target suite are in `docs/ci/host-gate-failures.md` (#956).
