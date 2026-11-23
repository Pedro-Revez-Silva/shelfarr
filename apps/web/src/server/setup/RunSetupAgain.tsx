import { Link, Navigate, useNavigate, useSearch } from "@tanstack/react-router";
import { useState } from "react";
import { useServerOverview } from "../../queries";
import { SettingsCard } from "../primitives";
import { setupFailureText } from "./SetupPage";
import { useRestartSetup, useSetupWriting } from "./queries";

export function RunSetupAgainCard() {
  const navigate = useNavigate();
  const restart = useRestartSetup();
  const writing = useSetupWriting();
  const unfinished = useServerOverview().data?.setup?.completed === false;
  const [error, setError] = useState<string | null>(null);
  const run = () => {
    if (writing) return;
    setError(null);
    restart.mutate(undefined, {
      onSuccess: (answer) => {
        void navigate({ to: "/server/setup", search: { step: answer.setup?.step } });
      },
      onError: (failure) => setError(setupFailureText(failure)),
    });
  };
  return (
    <SettingsCard id="setup" headingId="run-setup-heading" title="Setup" summary="Go through the first-run steps again: Prowlarr, qBittorrent, folders, Audiobookshelf and how requests start. Saved settings are kept and shown on each step.">
      {unfinished ? <p className="field-hint">Setup has not been finished. Your saved settings are shown on each step.</p> : null}
      <div className="settings-card-actions">
        {unfinished ? (
          <Link to="/server/setup" className="button button--primary">
            Continue setup
          </Link>
        ) : (
          <button type="button" className="button" disabled={writing} aria-busy={restart.isPending} onClick={run}>
            {restart.isPending ? "Starting…" : "Run setup again"}
          </button>
        )}
      </div>
      <div role="status">{error ? <p className="form-error">{error}</p> : null}</div>
    </SettingsCard>
  );
}

export function SetupReminder() {
  return (
    <section className="overview-card setup-reminder" aria-labelledby="setup-reminder-heading">
      <h2 id="setup-reminder-heading">Shelfarr is not set up yet</h2>
      <p className="overview-note">Connect an indexer and a download client so requests can finish on their own.</p>
      <p>
        <Link to="/server/setup" className="button button--primary">
          Start setup
        </Link>
      </p>
    </section>
  );
}

export function LegacySetupRedirect() {
  const { step } = useSearch({ from: "/admin/setup_wizard" });
  return <Navigate to="/server/setup" search={{ step }} replace />;
}
