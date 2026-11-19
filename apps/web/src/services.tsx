import { QueryClient } from "@tanstack/react-query";
import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react";
import { AccountGuard, type GuardState } from "./api/account-guard";
import { ApiClient, type MutationLifecycle } from "./api/client";
import { isApiError } from "./api/errors";
import type { Boot, LibraryFilters, RequestFilters } from "./contract";

export type Mode = "rails" | "go";

export type Services = {
  boot: Boot;
  mode: Mode;
  guard: AccountGuard;
  api: ApiClient;
  queryClient: QueryClient;
  keys: QueryKeys;
  revalidate: () => void;
};

export type QueryKeys = ReturnType<typeof createQueryKeys>;

export type RequestScope = "own" | "all";

export function createQueryKeys(account: string) {
  const root = ["account", account] as const;
  return {
    root,
    session: [...root, "session"] as const,
    profile: [...root, "profile"] as const,
    continueReading: (filters: Pick<LibraryFilters, "type">) => [...root, "continue", filters.type ?? null] as const,
    library: (filters: LibraryFilters) => [...root, "library", filters.q ?? "", filters.type ?? null, filters.status ?? null, filters.sort ?? "recent"] as const,
    libraryAll: [...root, "library"] as const,
    continueAll: [...root, "continue"] as const,
    publication: (id: string) => [...root, "publication", id] as const,
    discover: (query: string | null) => [...root, "discover", query] as const,
    requests: (scope: RequestScope, filters: RequestFilters) => [...root, "requests", scope, filters.status ?? null, filters.attention ?? null, filters.q ?? "", filters.page ?? "1"] as const,
    request: (scope: RequestScope, id: string) => [...root, "request", scope, id] as const,
  };
}

const VALIDATION_TIMEOUT_MS = 8000;

function sessionLost(error: unknown): "signed_out" | "account_changed" | null {
  if (!isApiError(error)) return null;
  if (error.kind === "signed_out") return "signed_out";
  if (error.kind === "account_changed" || error.kind === "not_found") return "account_changed";
  return null;
}

export type ServiceInputs = {
  guard?: AccountGuard;
  validationTimeoutMs?: number;
  boot: Boot;
  csrfToken: () => string | null;
  fetcher?: typeof fetch;
  mutations?: MutationLifecycle;
};

export function createServices({ boot, csrfToken, fetcher, mutations, guard: suppliedGuard, validationTimeoutMs = VALIDATION_TIMEOUT_MS }: ServiceInputs): Services {
  const guard = suppliedGuard ?? new AccountGuard(boot.account);
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        networkMode: "always",
        staleTime: 30_000,
        gcTime: 10 * 60_000,
        refetchOnReconnect: true,
        retry: (count, error) => (isApiError(error) ? (error.kind === "network" || error.kind === "server" || error.kind === "busy") && count < 2 : count < 1),
      },
      mutations: { retry: false, networkMode: "always" },
    },
  });
  guard.subscribe(() => {
    void queryClient.cancelQueries();
    queryClient.clear();
  });
  let requestVerificationRef: () => void = () => undefined;
  const requestVerification = () => requestVerificationRef();
  const deps = { boot, guard, csrfToken, requestVerification, ...(fetcher ? { fetcher } : {}), ...(mutations ? { mutations } : {}) };
  const api = new ApiClient(deps);
  const keys = createQueryKeys(boot.account);
  const verify = async (generation: number): Promise<void> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), validationTimeoutMs);
    try {
      const session = await api.session(controller.signal, true);
      if (generation === guard.generation && guard.isActive()) queryClient.setQueryData(keys.session, session);
      guard.finishCheck(generation, true);
    } catch (error) {
      const lost = sessionLost(error);
      if (lost && generation === guard.generation) guard.lock(lost);
      else guard.finishCheck(generation, false);
    } finally {
      clearTimeout(timer);
    }
  };
  let scheduled = false;
  const revalidate = () => {
    if (!guard.isActive()) return;
    guard.invalidate();
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      void verify(guard.generation);
    }, 0);
  };
  requestVerificationRef = revalidate;
  return { boot, mode: boot.runtime === "go" ? "go" : "rails", guard, api, queryClient, keys, revalidate };
}

const ServicesContext = createContext<Services | null>(null);

export function ServicesProvider({ services, children }: { services: Services; children: ReactNode }) {
  return <ServicesContext.Provider value={services}>{children}</ServicesContext.Provider>;
}

export function useServices(): Services {
  const services = useContext(ServicesContext);
  if (!services) throw new Error("Services are missing");
  return services;
}

export function useGuardState(): GuardState {
  const { guard } = useServices();
  return useSyncExternalStore(guard.subscribe, guard.getState, guard.getState);
}
