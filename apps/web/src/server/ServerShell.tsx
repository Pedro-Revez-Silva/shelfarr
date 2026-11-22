import type { ReactNode } from "react";
import { PageHeading } from "../components/PageHeading";
import { serverCategoryIds, type ServerCategoryId, type ServerSettings } from "./contract";
import { SettingsRail, type RailItem } from "./primitives";
import "./server.css";

export const CATEGORY_LABELS: Record<ServerCategoryId, string> = {
  policy: "Request policy",
  sources: "Catalogues and sources",
  downloads: "Downloads",
  library: "Library and files",
  notifications: "Notifications",
  people: "People and access",
  system: "System",
};

export const LEGACY_SETTINGS_TABS: Record<string, ServerCategoryId> = {
  search: "sources",
  downloads: "library",
  integrations: "sources",
  system: "system",
  security: "people",
};

export function isCategory(value: string): value is ServerCategoryId {
  return (serverCategoryIds as readonly string[]).includes(value);
}

export function railItems(current: ServerCategoryId | "overview", settings: ServerSettings | undefined): RailItem[] {
  const titles = new Map(settings?.categories.map((category) => [category.id, category.title]));
  return [
    { id: "overview", label: "Overview", to: "/server", current: current === "overview" },
    ...serverCategoryIds.map((id) => ({ id, label: titles.get(id) ?? CATEGORY_LABELS[id], to: "/server/$category", params: { category: id }, current: current === id })),
  ];
}

export function ServerShell({
  current,
  settings,
  headingId,
  title,
  summary,
  rail,
  children,
}: {
  current: ServerCategoryId | "overview";
  settings: ServerSettings | undefined;
  headingId: string;
  title: string;
  summary: ReactNode;
  rail: boolean;
  children: ReactNode;
}) {
  return (
    <section className="server" aria-labelledby={headingId}>
      <header className="page-heading server-heading">
        <p className="eyebrow">Server</p>
        <PageHeading id={headingId}>{title}</PageHeading>
        <p className="lede">{summary}</p>
        <p className="server-scope">These apply to everyone on this server.</p>
      </header>
      <div className="server-layout">
        {rail ? <SettingsRail label="Server" items={railItems(current, settings)} /> : null}
        <div className="server-content">{children}</div>
      </div>
    </section>
  );
}
