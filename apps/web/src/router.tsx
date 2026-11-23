import { createRootRoute, createRoute, createRouter, redirect, type RouterHistory } from "@tanstack/react-router";
import { bookSearchSchema, discoverSearchSchema, libraryFiltersSchema, requestFiltersSchema, setupSearchSchema } from "./contract";
import { AccountPage, AccountSectionPage } from "./components/AccountPage";
import { AdminPage, ServerHomePage } from "./components/AdminPage";
import { BookPage } from "./components/BookPage";
import { DetailsPage } from "./components/DetailsPage";
import { DiscoverPage, FindPage } from "./components/DiscoverPage";
import { LibraryPage } from "./components/LibraryPage";
import { RequestPage } from "./components/RequestPage";
import { RequestsPage } from "./components/RequestsPage";
import { ServerSettingsPage } from "./components/ServerSettingsPage";
import { ServerCategoryPage } from "./server/ServerCategoryPage";
import { LegacySetupRedirect } from "./server/setup/RunSetupAgain";
import { ServerSetupPage } from "./server/setup/SetupPage";
import { Shell } from "./components/Shell";
import { EmptyState } from "./components/States";

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

const routeTree = rootRoute.addChildren([indexRoute, libraryRoute, publicationRoute, accountRoute, accountSectionRoute, discoverRoute, findRoute, bookRoute, requestsRoute, requestRoute, adminRoute, serverSettingsRoute, serverRoute, serverSetupRoute, legacySetupRoute, serverCategoryRoute]);

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
