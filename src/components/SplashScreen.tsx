// Branded auth splash (#294). KEEP-IN-SYNC: the native SplashView
// (native/SendmeterNative/Sources/App/SendmeterNativeApp.swift) mirrors this
// layout and ports the `.splash-dyno` motion as SplashDynoTimeline
// (native/SendmeterNative/Sources/Core/SplashDynoTimeline.swift) — if you
// change the layout or the keyframes here, update those (and the
// SplashDynoTimeline unit tests) alongside.
export default function SplashScreen() {
  return (
    <div className="app-shell splash-screen" role="status" aria-label="Starting Sendmeter">
      <img
        className="splash-cave-background"
        src="/splash-cave-background.webp"
        width="941"
        height="1672"
        alt=""
        aria-hidden="true"
      />
      <div className="splash-content">
        <div className="splash-stage" aria-hidden="true">
          <img
            className="splash-kangaroo"
            src="/splash-kangaroo.webp"
            width="1254"
            height="1254"
            alt=""
          />
        </div>
      </div>
    </div>
  );
}
