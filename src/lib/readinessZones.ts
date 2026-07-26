/// Color per readiness zone (`health_metrics.zone`, computed in
/// sendlog-health-core). Lives here rather than next to ReadinessCard so
/// every surface showing the score — the card, the #224 projection card's
/// "today" footer — tints it identically; one number in two hues reads as
/// two numbers.
export const ZONE_COLORS: Record<string, string> = {
  push: "var(--success)",
  maintain: "var(--warning)",
  recover: "var(--danger)",
};
