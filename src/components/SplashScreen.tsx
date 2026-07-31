export default function SplashScreen() {
  return (
    <div className="app-shell splash-screen" role="status" aria-label="Starting Sendmeter">
      <div className="splash-content">
        <div className="splash-stage" aria-hidden="true">
          <img
            className="splash-logo"
            src="/icon-512.png"
            width="512"
            height="512"
            alt=""
          />
          <div className="splash-logo-shadow" />
        </div>
        <div className="splash-wordmark">SENDMETER</div>
        <div className="splash-tagline">Climbing training</div>
      </div>
    </div>
  );
}
