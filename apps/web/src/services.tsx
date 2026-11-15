import { QueryClient } from "@tanstack/react-query";
import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react";
import { AccountGuard, type GuardState } from "./api/account-guard";
import { ApiClient } from "./api/client";
import { isApiError } from "./api/errors";
import type { Boot, LibraryFilters } from "./contract";

export type Services = {
  boot: Boot;
  guard: AccountGuard;
  api: ApiClient;
  queryClient: QueryClient;
  keys: QueryKeys;
  revalidate: () => Promise<boolean>;
};

export type QueryKeys = ReturnType<typeof createQueryKeys>;

export function createQueryKeys(account: string) {
  const root = ["account", account] as const;
  return {
    root,
    session: [...root, "session"] as const,
    continueReading: (filters: Pick<LibraryFilters, "type">) => [...root, "continue", filters.type ?? null] as const,
    library: (filters: LibraryFilters) => [...root, "library", filters.q ?? "", filters.type ?? null, filters.status ?? null, filters.sort ?? "recent"] as const,
    libraryAll: [...root, "library"] as const,
    continueAll: [...root, "continue"] as const,
    publication: (id: string) => [...root, "publication", id] as const,
  };
}

const COALESCE_MS = 500;
const VALIDATION_TIMEOUT_MS = 8000;

export type ServiceInputs = {
  validationTimeoutMs?: number;
  boot: Boot;
  csrfToken: () => string | null;
  fetcher?: typeof fetch;
};

export function createServices({ boot, csrfToken, fetcher, validationTimeoutMs = VALIDATION_TIMEOUT_MS }: ServiceInputs): Services {
  const guard = new AccountGuard(boot.account);
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        networkMode: "always",
        staleTime: 30_000,
        gcTime: 10 * 60_000,
        refetchOnReconnect: true,
        retry: (count, error) => (isApiError(error) ? (error.kind === "network" || error.kind === "server") && count < 2 : count < 1),
      },
      mutations: { retry: false, networkMode: "always" },
    },
  });
  guard.subscribe(() => {
    void queryClient.cancelQueries();
    queryClient.clear();
  });
  const deps = fetcher ? { boot, guard, csrfToken, fetcher } : { boot, guard, csrfToken };
  const api = new ApiClient(deps);
  const keys = createQueryKeys(boot.account);
  const verify = async (): Promise<boolean> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), validationTimeoutMs);
    try {
      queryClient.setQueryData(keys.session, await api.session(controller.signal));
      return true;
    } catch {
      return false;
    } finally {
      clearTimeout(timer);
    }
  };
  const revalidate = () => {
    if (!guard.isActive()) return Promise.resolve(false);
    if (guard.recentValidationPending(COALESCE_MS)) return guard.confirmed();
    return guard.track(verify());
  };
  return { boot, guard, api, queryClient, keys, revalidate };
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
