function Block({ className = "" }: { className?: string }) {
  return <div className={`skeleton-block${className ? ` ${className}` : ""}`} />;
}

export default function TrainingDataSkeleton() {
  return (
    <div className="training-skeleton" role="status" aria-label="Loading your training">
      <div aria-hidden="true">
        <div className="skeleton-context-row">
          <div className="phase-banner skeleton-card skeleton-phase-card">
            <Block className="skeleton-line skeleton-line-wide" />
            <Block className="skeleton-line skeleton-line-medium" />
            <Block className="skeleton-pill" />
          </div>
          <div className="card skeleton-card skeleton-conditions-card">
            <Block className="skeleton-line skeleton-line-short" />
            <Block className="skeleton-score skeleton-score-small" />
            <Block className="skeleton-line skeleton-line-medium" />
          </div>
        </div>

        <div className="card skeleton-card skeleton-readiness-card">
          <Block className="skeleton-line skeleton-line-medium" />
          <Block className="skeleton-score" />
          <Block className="skeleton-line skeleton-line-short" />
          <div className="skeleton-chart-line" />
        </div>

        <div className="card skeleton-card skeleton-acwr-card">
          <Block className="skeleton-line skeleton-line-short" />
          <Block className="skeleton-score skeleton-score-medium" />
          <Block className="skeleton-line skeleton-line-short" />
          <Block className="skeleton-track" />
          <div className="skeleton-stat-row">
            <Block className="skeleton-line skeleton-line-medium" />
            <Block className="skeleton-line skeleton-line-medium" />
          </div>
        </div>

        <div className="card skeleton-card skeleton-projection-card">
          <Block className="skeleton-line skeleton-line-medium" />
          <Block className="skeleton-line skeleton-line-short" />
          <div className="skeleton-chart-line" />
        </div>
      </div>
    </div>
  );
}
