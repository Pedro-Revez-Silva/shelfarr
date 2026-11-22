import { Link, useLocation } from "@tanstack/react-router";
import { useId } from "react";
import type { RequestSummary } from "../contract";
import { useRequests } from "../queries";
import { useServices } from "../services";
import { StatusBadges } from "./requestText";

const OPEN_STATUSES = new Set<RequestSummary["status"]>(["pending", "searching", "not_found", "downloading", "processing", "awaiting_purchase"]);
const SHOWN = 5;

export function FindTabs() {
  const { mode, boot } = useServices();
  const pathname = useLocation({ select: (location) => location.pathname.slice(boot.mount.replace(/\/$/, "").length) });
  const onRequests = pathname.startsWith("/requests");
  return (
    <nav className="find-tabs" aria-label="Find">
      <ul>
        <li>
          <Link to={mode === "go" ? "/discover" : "/find"} className="filter-link" aria-current={onRequests ? undefined : "page"} activeProps={{}}>
            Search
          </Link>
        </li>
        <li>
          <Link to="/requests" className="filter-link" aria-current={onRequests ? "page" : undefined} activeProps={{}}>
            Requests
          </Link>
        </li>
      </ul>
    </nav>
  );
}

export function YourRequests() {
  const list = useRequests({});
  const headingId = useId();
  const open = (list.data?.items ?? []).filter((request) => OPEN_STATUSES.has(request.status) && (list.data?.scope !== "all" || request.requested_by?.self !== false)).slice(0, SHOWN);
  if (!list.data || open.length === 0) {
    return list.data ? (
      <p className="find-requests-link">
        <Link to="/requests">All requests</Link>
      </p>
    ) : null;
  }
  return (
    <section className="your-requests" aria-labelledby={headingId}>
      <div className="section-heading">
        <h2 id={headingId}>Your requests</h2>
        <Link to="/requests">All requests</Link>
      </div>
      <ul className="your-requests-list">
        {open.map((request) => (
          <li key={request.id}>
            <Link to="/requests/$requestId" params={{ requestId: request.id }} className="request-link">
              {request.title}
            </Link>
            {request.author ? <span className="request-meta"> · {request.author}</span> : null}
            <StatusBadges request={request} />
          </li>
        ))}
      </ul>
    </section>
  );
}
