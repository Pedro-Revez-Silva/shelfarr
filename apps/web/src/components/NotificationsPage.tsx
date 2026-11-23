import { Link } from "@tanstack/react-router";
import { useEffect, useRef, useState, type FocusEvent } from "react";
import { isApiError } from "../api/errors";
import type { NotificationChange, NotificationItem, NotificationList } from "../contract";
import { useNotificationCommand, useNotifications, type NotificationCommand } from "../notifications";
import { RemoveZone } from "../server/primitives";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { PageHeading } from "./PageHeading";
import { actionFailure, Time } from "./requestText";
import { EmptyState, ErrorPanel, Loading } from "./States";

const HEADING_ID = "notifications-heading";
const NOT_SENT = "That did not reach the server. Check your connection and try again.";

const TONES: Record<string, { mark: string; tone: string }> = {
  request_completed: { mark: "✓", tone: "ready" },
  request_failed: { mark: "✕", tone: "failed" },
  request_attention: { mark: "!", tone: "attention" },
};

type Said = { text: string; tone: "success" | "error"; serial: number };
type FocusTarget = { kind: "heading" } | { kind: "item"; id: string } | null;

export function NotificationsPage() {
  const { mode } = useServices();
  usePageTitle("Notifications");
  if (mode === "go") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <Inbox />;
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

function outcomeText(command: NotificationCommand, answer: NotificationChange, title: string | null): string {
  if (command.kind === "read") return answer.changed > 0 ? `Marked “${title ?? "the notification"}” as read.` : `“${title ?? "That notification"}” was already read.`;
  if (command.kind === "read_all") {
    if (answer.unread === 0) return "All notifications marked as read.";
    return `Marked ${plural(answer.changed, "notification")} as read. ${plural(answer.unread, "newer notification")} arrived and ${answer.unread === 1 ? "stays" : "stay"} unread.`;
  }
  if (answer.total === 0) return "All notifications cleared.";
  return `Cleared ${plural(answer.changed, "notification")}. ${plural(answer.total, "newer notification")} arrived and ${answer.total === 1 ? "was" : "were"} kept.`;
}

function Inbox() {
  const { revalidate } = useServices();
  const list = useNotifications();
  const command = useNotificationCommand();
  const [said, setSaid] = useState<Said | null>(null);
  const [focus, setFocus] = useState<FocusTarget>(null);
  const serial = useRef(0);
  const current = list.isError ? undefined : list.data;
  const fetchedAt = list.dataUpdatedAt;

  useEffect(() => {
    if (!focus || list.isFetching) return;
    const target = focus.kind === "heading" ? document.getElementById(HEADING_ID) : document.getElementById(itemHeadingId(focus.id));
    (target ?? document.getElementById(HEADING_ID))?.focus();
    setFocus(null);
  }, [focus, fetchedAt, list.isFetching]);

  const say = (tone: Said["tone"], text: string) => {
    serial.current += 1;
    setSaid({ tone, text, serial: serial.current });
  };

  const run = (input: NotificationCommand, title: string | null = null) => {
    command.mutate(input, {
      onSuccess: (answer) => {
        say("success", outcomeText(input, answer, title));
        setFocus(input.kind === "read" ? { kind: "item", id: input.id } : { kind: "heading" });
      },
      onError: (error) => {
        if (input.kind === "read" && isApiError(error) && error.kind === "not_found") {
          revalidate();
          say("error", "That notification is no longer here. The list now shows what is left.");
          setFocus({ kind: "heading" });
          return;
        }
        say("error", actionFailure(error, NOT_SENT));
      },
    });
  };

  return (
    <section className="notifications" aria-labelledby={HEADING_ID}>
      <header className="page-heading">
        <PageHeading id={HEADING_ID}>Notifications</PageHeading>
        <p className="lede">Updates about the books you asked for. Only you see these.</p>
      </header>

      {current ? <Toolbar list={current} busy={command.isPending} onCommand={run} /> : null}

      <div className="notifications-status" role="status">
        {said ? (
          <p key={said.serial} className={said.tone === "error" ? "form-error" : "form-success"}>
            {said.text}
          </p>
        ) : null}
      </div>

      {list.isPending ? <Loading label="Loading notifications…" /> : null}
      {list.isError ? <ErrorPanel error={list.error} onRetry={() => void list.refetch()} /> : null}
      {current ? <Notifications list={current} busy={command.isPending} onCommand={run} /> : null}
    </section>
  );
}

function useFocusKeptAcross(snapshot: string) {
  const zone = useRef<HTMLSpanElement>(null);
  const seen = useRef(snapshot);
  const holding = useRef(false);
  useEffect(() => {
    if (seen.current === snapshot) return;
    seen.current = snapshot;
    if (holding.current && document.activeElement === document.body) zone.current?.querySelector("button")?.focus();
  }, [snapshot]);
  const onFocus = () => {
    holding.current = true;
  };
  const onBlur = (event: FocusEvent<HTMLSpanElement>) => {
    holding.current = event.currentTarget.contains(event.relatedTarget as Node | null);
  };
  return { zone, onFocus, onBlur };
}

function Toolbar({ list, busy, onCommand }: { list: NotificationList; busy: boolean; onCommand: (command: NotificationCommand) => void }) {
  const through = list.through;
  const snapshot = `${through}:${list.total}`;
  const { zone, onFocus, onBlur } = useFocusKeptAcross(snapshot);
  if (list.total === 0 || !through) return null;
  const shown = list.items.length < list.total ? `Showing the ${list.items.length} most recent of ${list.total}.` : null;
  return (
    <div className="notifications-toolbar">
      <p className="result-count">
        {list.unread > 0 ? `${list.unread} unread · ` : "All read · "}
        {plural(list.total, "notification")}
        {shown ? ` · ${shown}` : null}
      </p>
      <div className="notifications-actions">
        {list.unread > 0 ? (
          <button type="button" className="button" disabled={busy} onClick={() => onCommand({ kind: "read_all", through })}>
            Mark all as read
          </button>
        ) : null}
        <span ref={zone} className="notifications-clear" onFocus={onFocus} onBlur={onBlur}>
          <RemoveZone
            key={snapshot}
            label="Clear all"
            confirmLabel="Clear all"
            question={`Delete ${list.total === 1 ? "this notification" : `all ${list.total} notifications`}? This can’t be undone.`}
            busy={busy}
            onRemove={() => onCommand({ kind: "clear", through })}
          />
        </span>
      </div>
    </div>
  );
}

function Notifications({ list, busy, onCommand }: { list: NotificationList; busy: boolean; onCommand: (command: NotificationCommand, title: string | null) => void }) {
  if (list.items.length === 0) {
    return (
      <EmptyState title="No notifications">
        <p>You’re all caught up!</p>
      </EmptyState>
    );
  }
  return (
    <ol className="notification-list" role="list" aria-label="Notifications, newest first">
      {list.items.map((item) => (
        <li key={item.id}>
          <NotificationCard item={item} busy={busy} onRead={() => onCommand({ kind: "read", id: item.id }, item.title)} />
        </li>
      ))}
    </ol>
  );
}

function itemHeadingId(id: string): string {
  return `notification-${id}`;
}

function NotificationCard({ item, busy, onRead }: { item: NotificationItem; busy: boolean; onRead: () => void }) {
  const unread = item.read_at === null;
  const look = TONES[item.type] ?? { mark: "•", tone: "other" };
  return (
    <article className={`notification notification--${look.tone}${unread ? " notification--unread" : ""}`} aria-labelledby={itemHeadingId(item.id)}>
      <span className="notification-mark" aria-hidden="true">
        {look.mark}
      </span>
      <div className="notification-copy">
        <h2 id={itemHeadingId(item.id)} tabIndex={-1}>
          {item.title}
          {unread ? (
            <>
              {" "}
              <span className="badge badge--unread">Unread</span>
            </>
          ) : null}
        </h2>
        {item.message ? <p>{item.message}</p> : null}
        <p className="request-meta">
          <Time iso={item.created_at} relative />
        </p>
        <div className="notification-actions">
          {item.request?.state === "available" ? (
            <Link to="/requests/$requestId" params={{ requestId: item.request.id }} className="button button--subtle">
              View request<span className="sr-only"> for {item.title}</span>
            </Link>
          ) : item.request?.state === "unavailable" ? (
            <p className="field-hint">This request is no longer available.</p>
          ) : null}
          {unread ? (
            <button type="button" className="button button--subtle" disabled={busy} onClick={onRead}>
              Mark as read<span className="sr-only"> {item.title}</span>
            </button>
          ) : null}
        </div>
      </div>
    </article>
  );
}
