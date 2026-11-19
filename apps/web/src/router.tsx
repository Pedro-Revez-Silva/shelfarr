import { createRootRoute, createRoute, createRouter, redirect, type RouterHistory } from "@tanstack/react-router";
import { discoverSearchSchema, libraryFiltersSchema, requestFiltersSchema } from "./contract";
import { AccountPage } from "./components/AccountPage";
import { AdminPage } from "./components/AdminPage";
import { DetailsPage } from "./components/DetailsPage";
import { DiscoverPage } from "./components/DiscoverPage";
import { LibraryPage } from "./components/LibraryPage";
import { RequestPage } from "./components/RequestPage";
import { RequestsPage } from "./components/RequestsPage";
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

const discoverRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/discover",
  validateSearch: (search: Record<string, unknown>) => discoverSearchSchema.parse(search),
  component: DiscoverPage,
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

const routeTree = rootRoute.addChildren([indexRoute, libraryRoute, publicationRoute, accountRoute, discoverRoute, requestsRoute, requestRoute, adminRoute]);

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
