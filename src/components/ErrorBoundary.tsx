import { Component, type ErrorInfo, type ReactNode } from "react";
import { captureAppError } from "../lib/monitoring";

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

/**
 * Catches uncaught render errors so a thrown component shows a recoverable
 * screen instead of a white one, and reports them (issue #227). Wraps the whole
 * app tree in `main.tsx`, so "Try again" re-mounts everything below it — enough
 * to recover from a transient bad render; "Reload" is the escape hatch when it
 * isn't.
 *
 * Render errors are the only thing React routes here: rejected promises and
 * plain `window.onerror` throws are Sentry's global handlers, not this.
 */
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    captureAppError(error, info.componentStack ?? undefined);
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;

    return (
      <div
        className="app-shell"
        style={{ alignItems: "center", justifyContent: "center" }}
      >
        <div className="loading-center" style={{ padding: "0 24px", maxWidth: 360 }}>
          <div className="topbar-title" style={{ fontSize: 22 }}>SENDMETER</div>
          <div style={{ fontSize: "var(--t-base)", fontWeight: 700, marginTop: 8 }}>
            Something broke
          </div>
          <div
            style={{
              fontSize: "var(--t-sm)",
              color: "var(--ink-muted)",
              textAlign: "center",
              marginTop: 4,
            }}
          >
            Nothing you logged is lost — it's all on your account. Try again, or
            reload the app.
          </div>
          <div style={{ display: "flex", gap: 8, marginTop: 16, width: "100%" }}>
            <button
              className="btn-primary"
              onClick={() => this.setState({ error: null })}
            >
              Try again
            </button>
            <button className="btn-ghost" onClick={() => window.location.reload()}>
              Reload
            </button>
          </div>
        </div>
      </div>
    );
  }
}
