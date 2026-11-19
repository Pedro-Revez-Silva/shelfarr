import {
  queryOptions,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import type { AccountAnswer } from "./api/client";
import { ApiError } from "./api/errors";
import type { LibraryFilters, LibraryPage, Profile, PublicationDetail, ReadingStatus, RequestFilters, RequestSummary, Session } from "./contract";
import { useServices, type RequestScope } from "./services";

export function useSession() {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.session,
    queryFn: ({ signal }) => api.session(signal),
    staleTime: 15_000,
    refetchOnWindowFocus: false,
  });
}

export function useContinueReading(filters: LibraryFilters, enabled: boolean) {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.continueReading(filters),
    queryFn: ({ signal }) => api.continueReading(filters, signal),
    enabled,
  });
}

export function useLibrary(filters: LibraryFilters) {
  const { api, keys } = useServices();
  return useInfiniteQuery({
    queryKey: keys.library(filters),
    queryFn: ({ pageParam, signal }) => api.library(filters, pageParam, signal),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last: LibraryPage) => last.next_cursor ?? undefined,
  });
}

export function usePublication(id: string) {
  const { api, keys } = useServices();
  return useQuery(
    queryOptions({
      queryKey: keys.publication(id),
      queryFn: ({ signal }) => api.publication(id, signal),
    }),
  );
}

export function useReadingStatus(id: string) {
  const { api, keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (status: ReadingStatus) => api.setReadingStatus(id, status),
    onSuccess: (publication: PublicationDetail) => {
      if (!guard.isActive()) return;
      client.setQueryData(keys.publication(id), publication);
      void client.invalidateQueries({ queryKey: keys.libraryAll });
      void client.invalidateQueries({ queryKey: keys.continueAll });
    },
  });
}

export function useDiscover(query: string | null) {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.discover(query),
    queryFn: ({ signal }) => api.discover(query, signal),
    enabled: ({ state }) => state.status !== "error",
    staleTime: ({ state }) => (state.data?.search === "available" ? (query === null ? 30_000 : 5 * 60_000) : 0),
    retry: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
  });
}

const REQUEST_REFRESH_MS = 15_000;
const MOVING_STATUSES = new Set(["pending", "searching", "downloading", "processing"]);

export function stillChanging(request: Pick<RequestSummary, "status" | "next_retry_at">): boolean {
  return MOVING_STATUSES.has(request.status) || (request.status === "not_found" && request.next_retry_at !== null);
}

export function useRequestScope(): RequestScope | null {
  const session = useSession();
  if (!session.data) return null;
  return session.data.admin ? "all" : "own";
}

function withinScope<T>(scope: RequestScope, broad: boolean, answer: T, revalidate: () => void): T {
  if (broad === (scope === "all")) return answer;
  revalidate();
  throw new ApiError("conflict", "The account's access changed while the answer was on its way");
}

export function useRequests(filters: RequestFilters) {
  const { api, keys, revalidate } = useServices();
  const known = useRequestScope();
  const scope = known ?? "own";
  return useQuery({
    queryKey: keys.requests(scope, filters),
    queryFn: async ({ signal }) => {
      const list = await api.requests(filters, signal);
      return withinScope(scope, list.scope === "all", list, revalidate);
    },
    enabled: known !== null,
    refetchInterval: ({ state }) => (state.data?.items.some(stillChanging) ? REQUEST_REFRESH_MS : false),
  });
}

export function useRequest(id: string) {
  const { api, keys, revalidate } = useServices();
  const known = useRequestScope();
  const scope = known ?? "own";
  return useQuery({
    queryKey: keys.request(scope, id),
    queryFn: async ({ signal }) => {
      const detail = await api.requestDetail(id, signal);
      return withinScope(scope, detail.requested_by !== undefined, detail, revalidate);
    },
    enabled: known !== null,
    refetchInterval: ({ state }) => (state.data && stillChanging(state.data) ? REQUEST_REFRESH_MS : false),
  });
}

export function useProfile() {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.profile,
    queryFn: ({ signal }) => api.account(signal),
  });
}

export function useDisplayName() {
  const { api, keys, guard } = useServices();
  const client = useQueryClient();
  const show = (profile: Profile) => {
    if (!guard.isActive()) return;
    client.setQueryData(keys.profile, profile);
    client.setQueryData<Session>(keys.session, (session) => (session ? { ...session, account: { ...session.account, name: profile.name } } : session));
    void client.invalidateQueries({ queryKey: keys.profile });
    void client.invalidateQueries({ queryKey: keys.session });
  };
  return useMutation({
    mutationFn: (name: string) => api.updateProfile(name),
    onSuccess: (answer: AccountAnswer) => {
      if (answer.kind === "saved") show(answer.profile);
    },
  });
}

export function flattenLibrary(data: InfiniteData<LibraryPage> | undefined) {
  if (!data) return [];
  const seen = new Set<string>();
  return data.pages.flatMap((page) => page.items).filter((item) => (seen.has(item.id) ? false : (seen.add(item.id), true)));
}
