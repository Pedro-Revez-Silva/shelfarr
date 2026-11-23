import { getRouteApi, Link, Navigate } from "@tanstack/react-router";
import { PageHeading } from "../../components/PageHeading";
import { AccountRail } from "../../components/PersonalSettings";
import { EmptyState, ErrorPanel, Loading } from "../../components/States";
import { useServices } from "../../services";
import { useDocumentTitle } from "../../title";
import type { CatalogueSearch } from "./contract";
import { DevicesBackLink } from "./KoboAccountPage";
import { CatalogueCard } from "./KoboCatalogue";
import { isMissing, useKoboCatalogue } from "./queries";
import "./kobo-accounts.css";

const routeApi = getRouteApi("/account/devices/kobo-shared/$accountId");

export function KoboSharedPage() {
  const { accountId } = routeApi.useParams();
  const search = routeApi.useSearch();
  return <SharedPage key={accountId} accountId={accountId} search={search} />;
}

function SharedPage({ accountId, search }: { accountId: string; search: CatalogueSearch }) {
  const { mode } = useServices();
  const catalogue = useKoboCatalogue(accountId, search);
  const shared = catalogue.data?.kobo_account;
  useDocumentTitle(shared ? `${shared.name} · Devices` : "Shared Kobo books · Devices");
  if (shared?.owner) return <Navigate to="/account/devices/kobo-accounts/$accountId" params={{ accountId }} search={search} replace />;
  const missing = catalogue.isError && isMissing(catalogue.error);
  return (
    <section className="account kobo-account" aria-labelledby="kobo-shared-heading">
      <DevicesBackLink hash="kobo-shared" />
      <PageHeading id="kobo-shared-heading">{shared?.name ?? "Shared Kobo books"}</PageHeading>
      <p className="lede">Only you see and change these.</p>
      <AccountRail current="devices" />
      {mode !== "rails" ? (
        <EmptyState title="Shared Kobo books are not available here">
          <p>This server does not manage Kobo accounts. Nothing was changed.</p>
        </EmptyState>
      ) : missing ? (
        <EmptyState title="This Kobo catalogue is not shared with you">
          <p>Its owner may have stopped sharing it or disconnected it. Copies already downloaded stay on your Kobo.</p>
          <Link to="/account/$section" params={{ section: "devices" }} hash="kobo-shared" className="button">
            Your devices
          </Link>
        </EmptyState>
      ) : shared ? (
        <div className="account-sections">
          <p className="muted">Shared with you by {shared.owner_name}. They can stop sharing at any time.</p>
          {shared.connected ? null : (
            <p role="status" className="kobo-tone kobo-tone--warning">
              This catalogue may be out of date: {shared.owner_name} needs to reconnect the Kobo account before new copies can be prepared.
            </p>
          )}
          <CatalogueCard accountId={accountId} search={search} route="/account/devices/kobo-shared/$accountId" />
        </div>
      ) : catalogue.isError ? (
        <ErrorPanel error={catalogue.error} onRetry={() => void catalogue.refetch()} />
      ) : (
        <Loading label="Loading this shared catalogue…" />
      )}
    </section>
  );
}
