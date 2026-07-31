import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import SplashScreen from "./SplashScreen";
import TrainingDataSkeleton from "./TrainingDataSkeleton";

describe("loading surfaces", () => {
  it("uses the bundled app icon for the branded splash", () => {
    const html = renderToStaticMarkup(<SplashScreen />);

    expect(html).toContain('role="status"');
    expect(html).toContain('aria-label="Starting Sendmeter"');
    expect(html).toContain('src="/icon-512.png"');
    expect(html).toContain("SENDMETER");
    expect(html).not.toContain("spinner");
  });

  it("renders dashboard-shaped placeholders while training data loads", () => {
    const html = renderToStaticMarkup(<TrainingDataSkeleton />);

    expect(html).toContain('aria-label="Loading your training"');
    expect(html).toContain("skeleton-phase-card");
    expect(html).toContain("skeleton-readiness-card");
    expect(html).toContain("skeleton-acwr-card");
    expect(html).toContain("skeleton-weekly-card");
    expect(html).toContain("skeleton-daily-card");
  });
});
