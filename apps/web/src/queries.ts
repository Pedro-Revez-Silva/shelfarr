import {
  queryOptions,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import type { AccountAnswer } from "./api/client";
import { ApiError, isApiError } from "./api/errors";
import type { Acquisition, LibraryFilters, LibraryPage, Profile, PublicationDetail, ReadingStatus, RequestFilters, RequestSummary, Session } from "./contract";
import { useServices } from "./services";

export function useSession() {
  const { api, keys, keepsRole } = useServices();
  return useQuery({
    queryKey: keys.session,
    queryFn: async ({ signal }) => {
      const session = await api.session(signal);
      if (!keepsRole(session)) throw new ApiError("account_changed", "This account's access changed");
      return session;
    },
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

function useRoleCheck() {
  const { queryClient, keys, guard } = useServices();
  return <T,>(broad: boolean, answer: T): T => {
    const session = queryClient.getQueryData<Session>(keys.session);
    if (session && broad === Boolean(session.admin)) return answer;
    guard.lock("access_changed");
    throw new ApiError("account_changed", "This account's access changed");
  };
}

export function useRequests(filters: RequestFilters) {
  const { api, keys } = useServices();
  const ready = useSession().data !== undefined;
  const check = useRoleCheck();
  return useQuery({
    queryKey: keys.requests(filters),
    queryFn: async ({ signal }) => {
      const list = await api.requests(filters, signal);
      return check(list.scope === "all", list);
    },
    enabled: ready,
    refetchInterval: ({ state }) => (state.data?.items.some(stillChanging) ? REQUEST_REFRESH_MS : false),
  });
}

export function useRequest(id: string) {
  const { api, keys, revalidate } = useServices();
  const ready = useSession().data !== undefined;
  const check = useRoleCheck();
  return useQuery({
    queryKey: keys.request(id),
    queryFn: async ({ signal }) => {
      const detail = await api.requestDetail(id, signal).catch((error: unknown) => {
        if (isApiError(error) && error.kind === "not_found") revalidate();
        throw error;
      });
      return check(detail.requested_by !== undefined, detail);
    },
    enabled: ready,
    refetchInterval: ({ state }) => (state.data && stillChanging(state.data) ? REQUEST_REFRESH_MS : false),
  });
}

export function useRequestEbook() {
  const { api, keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (workId: string) => api.requestEbook(workId),
    onSuccess: () => {
      if (!guard.isActive()) return;
      void client.invalidateQueries({ queryKey: keys.requestsAll });
    },
  });
}

const SELECTION_REFRESH_MS = 2_000;

export function selectionRunning(answer: Acquisition | undefined): boolean {
  return answer?.selection?.state === "queued" || answer?.selection?.state === "downloading";
}

export function useAcquisition(id: string, enabled: boolean, retryScheduled: boolean) {
  const { api, keys, revalidate } = useServices();
  return useQuery({
    queryKey: keys.acquisition(id),
    queryFn: ({ signal }) =>
      api.acquisition(id, signal).catch((error: unknown) => {
        if (isApiError(error) && error.kind === "not_found") revalidate();
        throw error;
      }),
    enabled,
    retry: false,
    refetchInterval: ({ state }) =>
      selectionRunning(state.data) ? SELECTION_REFRESH_MS : state.data && (MOVING_STATUSES.has(state.data.request.status) || (state.data.request.status === "not_found" && retryScheduled)) ? REQUEST_REFRESH_MS : false,
  });
}

export function useSelectResult(id: string) {
  const { api, keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (resultId: string) => api.selectResult(id, resultId),
    onSettled: () => {
      if (!guard.isActive()) return;
      void client.invalidateQueries({ queryKey: keys.acquisition(id) });
    },
  });
}

export function useSelectionFinished(id: string) {
  const { keys, guard } = useServices();
  const client = useQueryClient();
  return () => {
    if (!guard.isActive()) return;
    void client.invalidateQueries({ queryKey: keys.request(id) });
    void client.invalidateQueries({ queryKey: keys.requestsAll });
    void client.invalidateQueries({ queryKey: keys.libraryAll });
    void client.invalidateQueries({ queryKey: keys.continueAll });
  };
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
