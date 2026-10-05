# #992 device bar — OWNER-GATED, PENDING (not claimed)

The issue's end-to-end bar is a **real-device** capture. On this host it cannot
run: `log collect` requires USB (over the network tunnel it fails
`Device not configured (6)` even when `devicectl` reports `connected`), and
`devicectl device sysdiagnose` fails with `CoreDeviceCLISupport.DiagnoseError
error 0`. **Nothing below has been executed; no device capture exists for this
lane.**

Owner commands (USB-attached):

```bash
# 1. Capture the device log after reproducing a launch/sync failure.
log collect --device-udid <UDID> --last 10m ~/Desktop/sendmeter-launch.logarchive

# 2. Read it with persisted levels only — NO --info / NO --debug:
log show ~/Desktop/sendmeter-launch.logarchive --predicate 'process == "Sendmeter"' --style compact

# 3. What to look for (the lines this lane raised), one greppable shape:
#    launch failure step=<step> domain=<domain> code=<code> class=<class> surfaced=<true|false>
#    sync/replay failure op=<operation> domain=<domain> code=<code> class=<class> surfaced=<true|false>
#    Real lines captured on the simulator in this lane (same shapes on device):
#      launch failure step=refresh-slice:sessions domain=NSURLErrorDomain code=-1009 class=offline surfaced=true
#      launch failure step=banner domain=Auth.AuthError code=1 class=authRejected surfaced=true
#      sync/replay failure op=watch-transmit domain=WCErrorDomain code=7005 class=unknown surfaced=false
#      sync/replay failure op=queue-upload:preset domain=NSURLErrorDomain code=-1009 class=offline surfaced=false
```

A friendly drive for the launch leg: cold-launch with the network off (or a
previous build's cache/queue state on disk) — the refresh funnel records
`step=refresh-slice:<slice>` (the first failed slice in the plan's stable
order) and, when the banner is up, `step=banner`.
