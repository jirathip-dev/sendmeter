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
        <div className="splash-wordmark">SENDMETER</div>
        <div className="splash-tagline">Climbing training</div>
      </div>
    </div>
  );
}
