import { useRef, useState, type ReactNode } from "react";
import type { ServerOverview } from "../contract";
import { useDocumentTitle } from "../title";
import { useOverviewAction } from "./queries";
import { ServerShell } from "./ServerShell";

type Release = NonNullable<ServerOverview["release"]>;
type Said = { tone: "success" | "error"; text: string; serial: number };
export type Say = (tone: Said["tone"], text: string) => void;

const ACTION_FAILED = "That did not reach the server. Check your connection and try again.";

export function useOverviewOutcome() {
  const [outcome, setOutcome] = useState<Said | null>(null);
  const serial = useRef(0);
  const say: Say = (tone, text) => {
    serial.current += 1;
    setOutcome({ tone, text, serial: serial.current });
  };
  return { outcome, say };
}

export function ServerOverviewShell({ children }: { children: ReactNode }) {
  useDocumentTitle("Server overview");
  return (
    <ServerShell current="overview" settings={undefined} headingId="overview-heading" title="Server overview" summary="Health, requests and releases for everyone on this server. Only administrators see this.">
      <div className="overview server-overview">{children}</div>
    </ServerShell>
  );
}

export function OverviewActions({ build }: { build: string }) {
  return (
    <dl className="overview-build">
      <dt>Build</dt>
      <dd>{build}</dd>
    </dl>
  );
}

export function OverviewOutcome({ outcome }: { outcome: Said | null }) {
  return (
    <div className="form-outcome" role="status">
      {outcome ? (
        <p key={outcome.serial} className={outcome.tone === "error" ? "form-error" : "form-success"}>
          {outcome.text}
        </p>
      ) : null}
    </div>
  );
}

export function RunHealthCheck({ say }: { say: Say }) {
  const action = useOverviewAction();
  const running = action.isPending && action.variables === "health_check";
  return (
    <p className="overview-actions">
      <button
        type="button"
        className="button"
        disabled={action.isPending}
        aria-busy={running}
        onClick={() =>
          action.mutate("health_check", {
            onSuccess: ({ outcome }) => say(outcome.tone, outcome.message),
            onError: () => say("error", ACTION_FAILED),
          })
        }
      >
        {running ? "Starting…" : "Run health check"}
      </button>
    </p>
  );
}

function latestText(latest: Release["latest"]): ReactNode {
  switch (latest.state) {
    case "unchecked":
      return "Not checked yet";
    case "available":
      return (
        <>
          {latest.version} is available
          {latest.release_url ? (
            <>
              {" · "}
              <a href={latest.release_url} target="_blank" rel="noopener noreferrer">
                Release notes
              </a>
            </>
          ) : null}
        </>
      );
    case "current":
      return "You're up to date";
    case "failed":
      return latest.message ? `Couldn't check: ${latest.message}` : "Couldn't check";
  }
}

export function ReleaseCard({ release, say }: { release: Release; say: Say }) {
  const action = useOverviewAction();
  const checking = action.isPending && action.variables === "update_check";
  const available = release.latest.state === "available";
  return (
    <section id="release" className={`overview-card${available ? " overview-card--alert" : ""}`} aria-labelledby="release-heading">
      <h2 id="release-heading">Release</h2>
      <p className="release-channel">{release.channel}</p>
      <dl className="release-facts">
        <dt>Build</dt>
        <dd className="release-build">{release.build}</dd>
        <dt>Updates</dt>
        <dd>{release.beta ? "Newest beta or stable build" : "Stable releases only"}</dd>
        <dt>Latest</dt>
        <dd>{latestText(release.latest)}</dd>
      </dl>
      {release.beta ? <p className="overview-note">This is a beta. It is ready to use, but some screens may still change before Shelfarr {release.series} is final.</p> : null}
      <p className="overview-actions">
        <button
          type="button"
          className="button"
          disabled={action.isPending}
          aria-busy={checking}
          onClick={() =>
            action.mutate("update_check", {
              onSuccess: ({ outcome }) => say(outcome.tone, outcome.message),
              onError: () => say("error", ACTION_FAILED),
            })
          }
        >
          {checking ? "Checking…" : "Check for updates"}
        </button>
      </p>
      <details className="settings-note">
        <summary>How to update or go back safely</summary>
        <p>Stop Shelfarr and back up its storage volume (/rails/storage) before every update.</p>
        <p>Docker Compose, with SHELFARR_VERSION={release.image_tag}:</p>
        <pre className="release-command">docker compose pull && docker compose up -d</pre>
        <p>Docker CLI:</p>
        <pre className="release-command">docker pull {release.image}</pre>
        <p>Database changes made by a newer build stay when you switch the image back. To go back, restore the backup you made, then start the earlier build.</p>
        <p>
          <a href={release.guide_url} target="_blank" rel="noopener noreferrer">
            Releases, backups and rollback
          </a>
        </p>
      </details>
    </section>
  );
}
