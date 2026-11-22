import {
  queryOptions,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import type { AccountAnswer, BookLocation, MetadataAnswer } from "./api/client";
import { ApiError, failureKind, isApiError, unconfirmed } from "./api/errors";
import type { Acquisition, Book, LibraryFilters, MetadataChange, MetadataSettings, LibraryPage, Profile, PublicationDetail, ReadingStatus, RequestFilters, RequestSummary, Session } from "./contract";
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
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

export function useServerOverview() {
  const { api, keys, revalidate } = useServices();
  const admin = useSession().data?.admin !== undefined;
  return useQuery({
    queryKey: keys.serverOverview,
    queryFn: ({ signal }) =>
      api.serverOverview(signal).catch((error: unknown) => {
        if (failureKind(error) === "not_found") revalidate();
        throw error;
      }),
    enabled: admin,
    gcTime: 0,
    refetchOnMount: "always",
  });
}

export type MetadataSource = {
  settings: MetadataSettings | null;
  error: unknown;
  pending: boolean;
  reload: () => void;
  save: (revision: string, change: MetadataChange) => Promise<MetadataAnswer>;
};

export function useMetadataSettings(admin: boolean): MetadataSource {
  const { api, guard, revalidate, queryClient, keys } = useServices();
  const trust = useSyncExternalStore(guard.subscribeTrust, guard.getTrust, guard.getTrust);
  const [shown, setShown] = useState<{ settings: MetadataSettings | null; error: unknown }>({ settings: null, error: null });
  const [pending, setPending] = useState(false);
  const issued = useRef(0);
  const latest = useRef(0);
  const trusted = useRef(false);
  const showing = useRef(false);
  const saving = useRef(false);
  const readAfterSave = useRef(false);
  const refused = useRef(false);
  const alive = useRef(true);
  const reading = useRef<AbortController | null>(null);
  trusted.current = trust === "trusted";

  const start = () => {
    reading.current?.abort();
    reading.current = null;
    issued.current += 1;
    latest.current = issued.current;
    return issued.current;
  };

  const refuse = useCallback(
    (error: unknown) => {
      refused.current = true;
      showing.current = false;
      setShown({ settings: null, error });
      revalidate();
    },
    [revalidate],
  );

  const read = useCallback(() => {
    if (!trusted.current || refused.current) return;
    if (saving.current) {
      readAfterSave.current = true;
      return;
    }
    const ticket = start();
    const controller = new AbortController();
    reading.current = controller;
    api.metadataSettings(controller.signal).then(
      (settings) => {
        if (latest.current !== ticket) return;
        showing.current = true;
        setShown({ settings, error: null });
      },
      (error: unknown) => {
        if (latest.current !== ticket || controller.signal.aborted) return;
        if (failureKind(error) === "not_found") refuse(error);
        else setShown({ settings: null, error });
      },
    );
  }, [api, refuse]);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      start();
    };
  }, []);

  useEffect(() => {
    if (!admin) return;
    if (trust !== "trusted") {
      start();
      showing.current = false;
      if (trust === "unverified" && !refused.current) setShown({ settings: null, error: new ApiError("network", "The account could not be confirmed; try again") });
      else setShown((current) => (current.settings ? { settings: null, error: null } : current));
      return;
    }
    if (!showing.current) read();
  }, [admin, trust, read]);

  const save = useCallback(
    async (revision: string, change: MetadataChange) => {
      saving.current = true;
      setPending(true);
      const ticket = start();
      try {
        const answer = await api.saveMetadataSettings(revision, change);
        if (latest.current === ticket && answer.kind !== "rejected") {
          showing.current = true;
          setShown({ settings: answer.settings, error: null });
        }
        if (answer.kind === "saved" && guard.isActive()) void queryClient.resetQueries({ queryKey: keys.discoverAll });
        return answer;
      } catch (error) {
        if (unconfirmed(error) && guard.isActive()) void queryClient.resetQueries({ queryKey: keys.discoverAll });
        if (failureKind(error) === "not_found") {
          if (latest.current === ticket) refuse(error);
        } else readAfterSave.current = true;
        throw error;
      } finally {
        saving.current = false;
        if (alive.current) setPending(false);
        if (readAfterSave.current && alive.current) {
          readAfterSave.current = false;
          showing.current = false;
          read();
        }
      }
    },
    [api, guard, keys, queryClient, read, refuse],
  );

  const reload = useCallback(() => (trusted.current ? read() : revalidate()), [read, revalidate]);
  return { settings: trust === "trusted" ? shown.settings : null, error: shown.error, pending, reload, save };
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

const BOOK_TRANSFER_MS = 3_000;
const BOOK_WAITING_MS = 10_000;
const BOOK_RETRY_MS = 60_000;
const TRANSFERRING_STAGES = new Set(["downloading", "processing"]);
const WAITING_STAGES = new Set(["queued", "searching"]);

export function bookRefreshInterval(book: Book | undefined): number | false {
  const requests = (book?.formats ?? []).flatMap((format) => (format.request ? [format.request] : []));
  if (requests.some((request) => TRANSFERRING_STAGES.has(request.stage))) return BOOK_TRANSFER_MS;
  if (requests.some((request) => WAITING_STAGES.has(request.stage) && !request.attention_needed)) return BOOK_WAITING_MS;
  if (requests.some((request) => request.attention_needed || (request.stage === "not_found" && request.next_retry_at !== null))) return BOOK_RETRY_MS;
  return false;
}

export function useCatalogue(query: string | null) {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.catalogue(query),
    queryFn: ({ signal }) => api.catalogue(query ?? "", signal),
    enabled: query !== null,
    staleTime: 5 * 60_000,
    retry: false,
    refetchOnWindowFocus: false,
  });
}

export function useBook(location: BookLocation) {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.book(location.source, location.id),
    queryFn: ({ signal }) => api.book(location, signal),
    refetchInterval: ({ state }) => bookRefreshInterval(state.data),
  });
}

function useBookChange<V, T>(location: BookLocation, send: (variables: V) => Promise<T>, after?: (answer: T) => Book | null) {
  const { keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: send,
    onSuccess: (answer: T) => {
      if (!guard.isActive()) return;
      const book = after?.(answer) ?? null;
      if (book) client.setQueryData(keys.book(location.source, location.id), book);
    },
    onSettled: () => {
      if (!guard.isActive()) return;
      void client.invalidateQueries({ queryKey: keys.book(location.source, location.id) });
      void client.invalidateQueries({ queryKey: keys.catalogueAll });
      void client.invalidateQueries({ queryKey: keys.libraryAll });
      void client.invalidateQueries({ queryKey: keys.continueAll });
    },
  });
}

export function useRequestBookEbook(location: BookLocation) {
  const { api } = useServices();
  return useBookChange(location, () => api.requestBookEbook(location), (answer) => answer.book);
}

export function useChooseCopy(location: BookLocation, requestId: string) {
  const { api } = useServices();
  return useBookChange(location, (resultId: string) => api.chooseCopy(requestId, resultId));
}

export function useSearchAgain(location: BookLocation, requestId: string) {
  const { api } = useServices();
  return useBookChange(location, () => api.searchAgain(requestId));
}

export function useCancelRequest(location: BookLocation, requestId: string) {
  const { api } = useServices();
  return useBookChange(location, () => api.cancelRequest(requestId));
}
