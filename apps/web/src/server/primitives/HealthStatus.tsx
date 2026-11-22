import { Time } from "../../components/requestText";
import type { CardHealthStatus } from "../contract";

const LABELS: Record<CardHealthStatus, string> = {
  healthy: "Healthy",
  degraded: "Degraded",
  down: "Down",
  not_configured: "Not configured",
  unknown: "Unknown status",
};

export function HealthStatus({ status, checkedAt, message }: { status: CardHealthStatus | null; checkedAt?: string | undefined; message?: string | undefined }) {
  const problem = status === "down" || status === "degraded";
  return (
    <p className={`health-status${status ? ` health-status--${status}` : ""}`}>
      <span className="health-dot" aria-hidden="true" />
      <span className="health-status-label">
        {problem ? <span aria-hidden="true">⚠ </span> : null}
        {status ? LABELS[status] : "Never checked"}
      </span>
      {checkedAt ? (
        <span className="health-status-time">
          · Checked <Time iso={checkedAt} relative />
        </span>
      ) : null}
      {message ? <span className="health-status-message">{message}</span> : null}
    </p>
  );
}
