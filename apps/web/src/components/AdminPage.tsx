import { Link } from "@tanstack/react-router";
import { useState, useSyncExternalStore } from "react";
import { failureKind } from "../api/errors";
import type { HealthService, HealthStatus, ServerOverview, ServiceHealth } from "../contract";
import { useServerOverview, useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { PageHeading } from "./PageHeading";
import { Time } from "./requestText";
import { EmptyState, ErrorPanel, Loading } from "./States";

const SERVICE_LABELS: Record<HealthService, string> = {
  indexer: "Indexer",
  download_client: "Download client",
  download_paths: "Download paths",
  output_paths: "Output paths",
  audiobookshelf: "Library platform",
  hardcover: "Hardcover",
};

const STATUS_LABELS: Record<HealthStatus, string> = {
  healthy: "Healthy",
  degraded: "Degraded",
  down: "Down",
  not_configured: "Not configured",
  unknown: "Unknown status",
};

const PROBLEMS = new Set<HealthStatus | null>(["degraded", "down"]);

export function AdminPage() {
  const { mode } = useServices();
  if (mode !== "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <Overview />;
}

function AdminsOnly() {
  return (
    <EmptyState title="Only administrators can see this page">
      <p>Use the navigation to return to your library.</p>
    </EmptyState>
  );
}

function Overview() {
  usePageTitle("Server overview");
  const { guard, queryClient, keys } = useServices();
  const [cachedAtEntry] = useState(() => queryClient.getQueryState(keys.serverOverview)?.dataUpdatedAt ?? 0);
  const session = useSession();
  const overview = useServerOverview();
  const trust = useSyncExternalStore(guard.subscribeTrust, guard.getTrust, guard.getTrust);
  const admin = session.data?.admin !== undefined;
  const current = trust === "trusted" && overview.dataUpdatedAt > cachedAtEntry ? overview.data : undefined;

  return (
    <section className="overview" aria-labelledby="overview-heading">
      <header className="page-heading">
        <p className="eyebrow">Admin</p>
        <PageHeading id="overview-heading">Server overview</PageHeading>
        <p className="lede">Users, books, requests and saved health results for everyone on this server.</p>
        {session.data && admin ? (
          <>
            <dl className="overview-build">
              <dt>Build</dt>
              <dd>{session.data.server.version}</dd>
            </dl>
            <p className="overview-links">
              <Link to="/admin/settings" className="button">
                Server settings
              </Link>
            </p>
          </>
        ) : null}
      </header>
      {session.isError && !session.data ? (
        <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
      ) : !session.data ? (
        <Loading label="Loading the server overview…" />
      ) : !admin || (overview.isError && failureKind(overview.error) === "not_found") ? (
        <AdminsOnly />
      ) : overview.isError ? (
        <ErrorPanel error={overview.error} onRetry={() => void overview.refetch()} />
      ) : current ? (
        <OverviewBody overview={current} />
      ) : (
        <Loading label="Loading the server overview…" />
      )}
    </section>
  );
}

function OverviewBody({ overview }: { overview: ServerOverview }) {
  const { counts } = overview;
  return (
    <>
      <Attention overview={overview} />
      <dl className="overview-counts">
        <Tally label="Users" value={counts.users} />
        <Tally label="Books" value={counts.books} />
        <Tally label="Requests in progress" value={counts.active_requests} />
        <Tally label="Need attention" value={counts.attention_requests} alert={counts.attention_requests > 0} />
      </dl>
      <section className="overview-card" aria-labelledby="health-heading">
        <h2 id="health-heading">System health</h2>
        <p className="overview-note">Saved results from the last health check. Opening this page does not run a check.</p>
        <ul className="health-list">
          {overview.services.map((entry) => (
            <HealthRow key={entry.service} entry={entry} />
          ))}
        </ul>
      </section>
    </>
  );
}

function Tally({ label, value, alert = false }: { label: string; value: number; alert?: boolean }) {
  return (
    <div className={`overview-tally${alert ? " overview-tally--alert" : ""}`}>
      <dt>{label}</dt>
      <dd>{value.toLocaleString("en")}</dd>
    </div>
  );
}

function Attention({ overview }: { overview: ServerOverview }) {
  const problems = overview.services.filter((entry) => PROBLEMS.has(entry.status));
  const waiting = overview.counts.attention_requests;
  const calm = problems.length === 0 && waiting === 0;
  return (
    <section className={`overview-card${calm ? "" : " overview-card--alert"}`} aria-labelledby="attention-heading">
      <h2 id="attention-heading">Needs attention</h2>
      {calm ? (
        <p className="overview-note">Nothing needs attention in the saved results.</p>
      ) : (
        <ul className="attention-list">
          {problems.map((entry) => (
            <li key={entry.service}>
              <span aria-hidden="true">⚠ </span>
              {SERVICE_LABELS[entry.service]} is {entry.status === "down" ? "down" : "degraded"}
            </li>
          ))}
          {waiting > 0 ? (
            <li className="attention-requests">
              <span>
                <span aria-hidden="true">⚠ </span>
                {waiting === 1 ? "1 request needs attention" : `${waiting.toLocaleString("en")} requests need attention`}
              </span>
              <Link to="/requests" search={{ attention: "true" }} className="button">
                Review requests
              </Link>
            </li>
          ) : null}
        </ul>
      )}
    </section>
  );
}

function HealthRow({ entry }: { entry: ServiceHealth }) {
  const status = entry.status;
  return (
    <li className="health-row">
      <span className="health-name">{SERVICE_LABELS[entry.service]}</span>
      <span className={`badge badge--health${status ? ` badge--${status}` : ""}`}>
        {PROBLEMS.has(status) ? <span aria-hidden="true">⚠</span> : null}
        {status ? STATUS_LABELS[status] : "Never checked"}
      </span>
      {status ? (
        <span className="health-checked">
          {entry.checked_at ? (
            <>
              Checked <Time iso={entry.checked_at} relative />
            </>
          ) : (
            "Not checked yet"
          )}
        </span>
      ) : null}
    </li>
  );
}
