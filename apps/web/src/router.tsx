import { createRootRoute, createRoute, createRouter, redirect, type RouterHistory } from "@tanstack/react-router";
import { bookSearchSchema, discoverSearchSchema, libraryFiltersSchema, requestFiltersSchema, setupSearchSchema } from "./contract";
import { AccountPage, AccountSectionPage } from "./components/AccountPage";
import { AdminPage, ServerHomePage } from "./components/AdminPage";
import { BookPage } from "./components/BookPage";
import { DetailsPage } from "./components/DetailsPage";
import { KoboReaderPage } from "./devices/kobo/KoboReaderPage";
import { DiscoverPage, FindPage } from "./components/DiscoverPage";
import { LibraryPage } from "./components/LibraryPage";
import { NotificationsPage } from "./components/NotificationsPage";
import { RequestPage } from "./components/RequestPage";
import { RequestsPage } from "./components/RequestsPage";
import { ServerSettingsPage } from "./components/ServerSettingsPage";
import { ServerCategoryPage } from "./server/ServerCategoryPage";
import { NewPersonPage, PersonPage } from "./server/people/PersonPages";
import { ActivityLogPage } from "./server/activity/ActivityLogPage";
import { activitySearchSchema } from "./server/activity/contract";
import { LegacySetupRedirect } from "./server/setup/RunSetupAgain";
import { ServerSetupPage } from "./server/setup/SetupPage";
import { Shell } from "./components/Shell";
import { EmptyState } from "./components/States";
import { uploadsSearchSchema } from "./uploads/contract";
import { UploadsPage } from "./uploads/UploadsPage";

function parseSearch(search: string): Record<string, string> {
  return Object.fromEntries(new URLSearchParams(search));
}

function stringifySearch(search: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(search)) {
    if (typeof value === "string" && value !== "") params.set(key, value);
  }
  const text = params.toString();
  return text ? `?${text}` : "";
}

const rootRoute = createRootRoute({
  component: Shell,
  notFoundComponent: () => (
    <EmptyState title="That page is not part of this preview">
      <p>Use the navigation to return to your library.</p>
    </EmptyState>
  ),
});

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  beforeLoad: () => {
    throw redirect({ to: "/library", replace: true });
  },
});

const libraryRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/library",
  validateSearch: (search: Record<string, unknown>) => libraryFiltersSchema.parse(search),
  component: LibraryPage,
});

const uploadsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/library/uploads",
  validateSearch: (search: Record<string, unknown>) => uploadsSearchSchema.parse(search),
  component: UploadsPage,
});

const publicationRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/library/$publicationId",
  component: DetailsPage,
});

const accountRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/account",
  component: AccountPage,
});

const accountSectionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/account/$section",
  component: AccountSectionPage,
});

const koboReaderRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/account/devices/kobo/$readerId",
  component: KoboReaderPage,
});

const discoverRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/discover",
  validateSearch: (search: Record<string, unknown>) => discoverSearchSchema.parse(search),
  component: DiscoverPage,
});

const findRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/find",
  validateSearch: (search: Record<string, unknown>) => discoverSearchSchema.parse(search),
  component: FindPage,
});

const bookRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$source/$sourceId",
  validateSearch: (search: Record<string, unknown>) => bookSearchSchema.parse(search),
  component: BookPage,
});

const requestsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/requests",
  validateSearch: (search: Record<string, unknown>) => requestFiltersSchema.parse(search),
  component: RequestsPage,
});

const requestRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/requests/$requestId",
  component: RequestPage,
});

const notificationsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/notifications",
  component: NotificationsPage,
});

const adminRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/admin",
  component: AdminPage,
});

const serverSettingsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/admin/settings",
  component: ServerSettingsPage,
});

const serverRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server",
  component: ServerHomePage,
});

const serverSetupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server/setup",
  validateSearch: (search: Record<string, unknown>) => setupSearchSchema.parse(search),
  component: ServerSetupPage,
});

const legacySetupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/admin/setup_wizard",
  validateSearch: (search: Record<string, unknown>) => setupSearchSchema.parse(search),
  component: LegacySetupRedirect,
});

const serverCategoryRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server/$category",
  component: ServerCategoryPage,
});

const activityRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server/system/activity",
  validateSearch: (search: Record<string, unknown>) => activitySearchSchema.parse(search),
  component: ActivityLogPage,
});

const newPersonRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server/people/users/new",
  component: NewPersonPage,
});

const personRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/server/people/users/$userId",
  component: PersonPage,
});

const routeTree = rootRoute.addChildren([indexRoute, libraryRoute, uploadsRoute, publicationRoute, accountRoute, accountSectionRoute, koboReaderRoute, discoverRoute, findRoute, bookRoute, requestsRoute, requestRoute, notificationsRoute, adminRoute, serverSettingsRoute, serverRoute, serverSetupRoute, legacySetupRoute, serverCategoryRoute, activityRoute, newPersonRoute, personRoute]);

export function createAppRouter(options: { basepath: string; history?: RouterHistory }) {
  return createRouter({
    routeTree,
    basepath: options.basepath || "/",
    ...(options.history ? { history: options.history } : {}),
    scrollRestoration: true,
    defaultPreload: false,
    parseSearch,
    stringifySearch,
  });
}

export type AppRouter = ReturnType<typeof createAppRouter>;

declare module "@tanstack/react-router" {
  interface Register {
    router: AppRouter;
  }
}
