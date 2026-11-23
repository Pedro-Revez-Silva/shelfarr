import { useBlocker, useLocation, useParams } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { failureKind } from "../api/errors";
import { EmptyState, ErrorPanel, Loading } from "../components/States";
import { useSession } from "../queries";
import { useServices } from "../services";
import { useDocumentTitle } from "../title";
import type { SettingCategory, SettingGroup } from "./contract";
import { DOWNLOAD_CARDS, DownloadManagement } from "./downloads/DownloadManagement";
import { SettingsGroupCard } from "./SettingsGroupCard";
import { CATEGORY_LABELS, isCategory, ServerShell } from "./ServerShell";
import { useIsAdministrator, useServerSettings } from "./queries";
import { RunSetupAgainCard } from "./setup/RunSetupAgain";
import { ServerUploads, UPLOAD_CARDS } from "../uploads/ServerUploads";
import { PeopleCard } from "./people/PeopleCard";
import { AcquisitionProviders, PROVIDER_CARDS } from "./providers/AcquisitionProviders";
import { ACTIVITY_CARDS, ActivityLogCard } from "./activity/ActivityLogPage";

export function AdministratorsOnly() {
  return (
    <EmptyState title="Only administrators can see this page">
      <p>Use the navigation to return to your library.</p>
    </EmptyState>
  );
}

export function NotInThisRuntime() {
  return (
    <EmptyState title="That page is not part of this preview">
      <p>Use the navigation to return to your library.</p>
    </EmptyState>
  );
}

export function ServerCategoryPage() {
  const { mode } = useServices();
  const { category } = useParams({ from: "/server/$category" });
  if (mode !== "rails" || !isCategory(category)) return <NotInThisRuntime />;
  return <CategoryView category={category} />;
}

function CategoryView({ category }: { category: keyof typeof CATEGORY_LABELS }) {
  const session = useSession();
  const admin = useIsAdministrator();
  const settings = useServerSettings();
  const found = settings.data?.categories.find((entry) => entry.id === category);
  const title = found?.title ?? CATEGORY_LABELS[category];
  useDocumentTitle(`${title} · Server`);
  const headingId = `server-${category}-heading`;

  return (
    <ServerShell current={category} settings={settings.data} headingId={headingId} title={title} summary={found?.summary ?? ""} rail={admin}>
      {session.isError && !session.data ? (
        <ErrorPanel error={session.error} onRetry={() => void session.refetch()} />
      ) : !session.data ? (
        <Loading label="Loading the server settings…" />
      ) : !admin || (settings.isError && failureKind(settings.error) === "not_found") ? (
        <AdministratorsOnly />
      ) : found && settings.data ? (
        <>
          {settings.isError ? (
            <RefreshProblem
              onRetry={(button) =>
                void settings.refetch().then((result) => {
                  const active = document.activeElement;
                  if (!result.isError && (active === button || active === document.body || active === null)) document.getElementById(headingId)?.focus();
                })
              }
            />
          ) : null}
          {category === "people" ? <PeopleCard /> : null}
          <CategoryCards category={found} settings={settings.data} />
          {category === "system" ? <RunSetupAgainCard /> : null}
        </>
      ) : settings.isError ? (
        <ErrorPanel error={settings.error} onRetry={() => void settings.refetch()} />
      ) : (
        <Loading label="Loading the server settings…" />
      )}
    </ServerShell>
  );
}

function RefreshProblem({ onRetry }: { onRetry: (button: HTMLButtonElement) => void }) {
  return (
    <p className="refresh-problem" role="alert">
      <span aria-hidden="true">⚠ </span>The latest settings could not be loaded. The page shows what was last read; your unsaved changes are kept.{" "}
      <button type="button" className="button button--subtle" onClick={(event) => onRetry(event.currentTarget)}>
        Try again
      </button>
    </p>
  );
}

function headings(groups: SettingGroup[]): { heading: string | null; groups: SettingGroup[] }[] {
  const runs: { heading: string | null; groups: SettingGroup[] }[] = [];
  for (const group of groups) {
    const heading = group.heading ?? null;
    const last = runs.at(-1);
    if (last && last.heading === heading) last.groups.push(group);
    else runs.push({ heading, groups: [group] });
  }
  return runs;
}

function CategoryCards({ category, settings }: { category: SettingCategory; settings: NonNullable<ReturnType<typeof useServerSettings>["data"]> }) {
  const dirty = useRef(new Set<string>());
  const [dirtyCount, setDirtyCount] = useState(0);
  const onDirtyChange = useCallback((id: string, isDirty: boolean) => {
    if (isDirty) dirty.current.add(id);
    else dirty.current.delete(id);
    setDirtyCount(dirty.current.size);
  }, []);
  const blocker = useBlocker({
    shouldBlockFn: ({ current, next }) => dirty.current.size > 0 && current.pathname !== next.pathname,
    enableBeforeUnload: () => dirty.current.size > 0,
    withResolver: true,
  });
  useScrollToCard(category.id);

  return (
    <>
      <nav className="card-index" aria-label={`${category.title} cards`}>
        <ul>
          {[...(category.id === "downloads" ? DOWNLOAD_CARDS : []), ...(category.id === "system" ? ACTIVITY_CARDS : []), ...category.groups, ...(category.id === "sources" ? PROVIDER_CARDS : []), ...(category.id === "library" ? UPLOAD_CARDS : [])].map((group) => (
            <li key={group.id}>
              <a href={`#${group.id}`}>{group.title}</a>
            </li>
          ))}
        </ul>
      </nav>
      {category.id === "downloads" ? <DownloadManagement onDirtyChange={onDirtyChange} /> : null}
      {category.id === "system" ? <ActivityLogCard /> : null}
      {headings(category.groups).map((run, index, runs) => (
        <div key={`${run.heading ?? "cards"}-${index}`} className="card-run" role={run.heading ? "group" : undefined} aria-label={run.heading ?? undefined}>
          {run.heading ? <h2 className="card-run-heading">{run.heading}</h2> : null}
          {run.groups.map((group) => (
            <SettingsGroupCard key={group.id} group={group} settings={settings} onDirtyChange={onDirtyChange} />
          ))}
          {category.id === "sources" && index === runs.length - 1 ? <AcquisitionProviders onDirtyChange={onDirtyChange} /> : null}
        </div>
      ))}
      {category.id === "library" ? <ServerUploads /> : null}
      {blocker.status === "blocked" ? <LeaveDialog count={dirtyCount} onStay={blocker.reset} onLeave={blocker.proceed} /> : null}
    </>
  );
}

function useScrollToCard(categoryId: string) {
  const hash = useLocation({ select: (location) => location.hash });
  useEffect(() => {
    if (!hash) return;
    const card = document.getElementById(hash);
    if (!card) return;
    card.scrollIntoView({ block: "start" });
    card.focus({ preventScroll: true });
  }, [hash, categoryId]);
}

export function LeaveDialog({ count, onStay, onLeave }: { count: number; onStay: () => void; onLeave: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const stay = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const element = dialog.current;
    if (element && typeof element.showModal === "function" && !element.open) element.showModal();
    stay.current?.focus();
  }, []);
  return (
    <dialog
      ref={dialog}
      className="leave-dialog"
      aria-labelledby="leave-dialog-title"
      aria-describedby="leave-dialog-text"
      onCancel={(event) => {
        event.preventDefault();
        onStay();
      }}
    >
      <h2 id="leave-dialog-title">Leave without saving?</h2>
      <p id="leave-dialog-text">{count === 1 ? "One card has changes that are not saved." : `${count} cards have changes that are not saved.`} They will be lost if you leave.</p>
      <div className="form-actions">
        <button ref={stay} type="button" className="button button--primary" onClick={onStay}>
          Stay and keep editing
        </button>
        <button type="button" className="button button--danger" onClick={onLeave}>
          Leave and discard
        </button>
      </div>
    </dialog>
  );
}
