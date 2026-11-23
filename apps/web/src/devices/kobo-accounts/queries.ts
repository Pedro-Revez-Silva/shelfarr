import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { failureKind, isApiError } from "../../api/errors";
import { describeWriteFailure } from "../../components/accountFields";
import { useServices } from "../../services";
import * as api from "./api";
import type { CatalogueSearch, KoboAccount, KoboAccounts, KoboBook } from "./contract";

export const POLL_INTERVAL_MS = 5000;

export function useKoboAccountKeys() {
  const { keys } = useServices();
  return useMemo(() => {
    const root = [...keys.root, "kobo-accounts"] as const;
    return {
      root,
      list: [...root, "list"] as const,
      account: (id: string) => [...root, "account", id] as const,
      catalogues: (id: string) => [...root, "catalogue", id] as const,
      catalogue: (id: string, search: CatalogueSearch) => [...root, "catalogue", id, search.filter ?? "all", search.page ?? "1"] as const,
      book: (id: string) => [...root, "book", id] as const,
    };
  }, [keys]);
}

const MISSING = new Set(["kobo_account_not_found", "kobo_book_not_found", "catalogue_not_found"]);

export function isMissing(error: unknown): boolean {
  return isApiError(error) && error.code !== null && MISSING.has(error.code);
}

export function koboAccountFailure(error: unknown, uncertain: string): string {
  if (!isApiError(error)) return uncertain;
  if (["kobo_limit_reached", "kobo_account_removed", "invalid_kobo_account"].includes(error.code ?? "")) return error.message;
  if (error.code === "kobo_account_not_found") return "This Kobo connection is no longer on your account. Nothing was changed.";
  if (error.code === "kobo_book_not_found") return "This book is no longer shared with you. Nothing was sent.";
  if (error.code === "reader_not_found") return "That Kobo reader is no longer connected to your account. Nothing was sent.";
  return describeWriteFailure(error, uncertain);
}

function keepTrying(count: number, error: unknown): boolean {
  return failureKind(error) !== "not_found" && count < 2;
}

export function useKoboAccounts() {
  const { api: client, mode } = useServices();
  return useQuery({ queryKey: useKoboAccountKeys().list, queryFn: ({ signal }) => api.accounts(client, signal), enabled: mode === "rails", refetchOnWindowFocus: false, staleTime: 0, retry: keepTrying });
}

export function useKoboAccount(id: string) {
  const { api: client, mode } = useServices();
  return useQuery({
    queryKey: useKoboAccountKeys().account(id),
    queryFn: ({ signal }) => api.koboAccount(client, id, signal),
    enabled: mode === "rails",
    refetchOnWindowFocus: false,
    staleTime: 0,
    retry: keepTrying,
    refetchInterval: (query) => (!isMissing(query.state.error) && query.state.data?.refreshing ? POLL_INTERVAL_MS : false),
  });
}

export function useKoboCatalogue(id: string, search: CatalogueSearch, enabled = true) {
  const { api: client, mode } = useServices();
  return useQuery({
    queryKey: useKoboAccountKeys().catalogue(id, search),
    queryFn: ({ signal }) => api.catalogue(client, id, search, signal),
    enabled: enabled && mode === "rails",
    refetchOnWindowFocus: false,
    staleTime: 0,
    retry: keepTrying,
    placeholderData: (previous) => previous,
  });
}

export function useKoboBook(id: string) {
  const { api: client, mode } = useServices();
  return useQuery({
    queryKey: useKoboAccountKeys().book(id),
    queryFn: ({ signal }) => api.book(client, id, signal),
    enabled: mode === "rails",
    refetchOnWindowFocus: false,
    staleTime: 0,
    retry: keepTrying,
    refetchInterval: (query) => (!isMissing(query.state.error) && query.state.data?.copy?.preparing ? POLL_INTERVAL_MS : false),
  });
}

export function usePublishAccount() {
  const { guard } = useServices();
  const keys = useKoboAccountKeys();
  const client = useQueryClient();
  return {
    active: () => guard.isActive(),
    account: (account: KoboAccount) => {
      if (!guard.isActive()) return;
      void client.cancelQueries({ queryKey: keys.account(account.id), exact: true }, { revert: false, silent: true });
      client.setQueryData(keys.account(account.id), account);
      client.setQueryData<KoboAccounts>(keys.list, (current) =>
        current ? { ...current, kobo_accounts: current.kobo_accounts.map((row) => (row.id === account.id ? { ...row, name: account.name, state: account.state, status_label: account.status_label, shared_with: account.shared_with } : row)) } : current,
      );
      void client.invalidateQueries({ queryKey: keys.list });
    },
    forget: (id: string) => {
      if (!guard.isActive()) return;
      client.removeQueries({ queryKey: keys.account(id), exact: true });
      client.removeQueries({ queryKey: keys.catalogues(id) });
      client.setQueryData<KoboAccounts>(keys.list, (current) => (current ? { ...current, kobo_accounts: current.kobo_accounts.filter((row) => row.id !== id) } : current));
      void client.invalidateQueries({ queryKey: keys.list });
    },
    book: (book: KoboBook) => {
      if (!guard.isActive()) return;
      void client.cancelQueries({ queryKey: keys.book(book.id), exact: true }, { revert: false, silent: true });
      client.setQueryData(keys.book(book.id), book);
    },
  };
}

export function useCatalogueFollowsRefresh(account: KoboAccount | undefined) {
  const keys = useKoboAccountKeys();
  const client = useQueryClient();
  const seen = useRef<string | null | undefined>(undefined);
  const id = account?.id;
  const synced = account?.last_synced_at;
  useEffect(() => {
    if (id === undefined) return;
    if (seen.current !== undefined && seen.current !== synced) {
      void client.invalidateQueries({ queryKey: keys.catalogues(id) });
      void client.invalidateQueries({ queryKey: keys.list });
    }
    seen.current = synced ?? null;
  }, [client, id, keys, synced]);
}

export function useAccountWrite<Input>(write: (input: Input) => Promise<api.AccountAnswer>) {
  const publish = usePublishAccount();
  return useMutation({
    mutationFn: write,
    onSuccess: (answer) => {
      if (publish.active()) publish.account(answer.kobo_account);
    },
  });
}

export function useBookWrite<Input>(write: (input: Input) => Promise<api.BookAnswer>) {
  const publish = usePublishAccount();
  return useMutation({
    mutationFn: write,
    onSuccess: (answer) => {
      if (publish.active()) publish.book(answer.book);
    },
  });
}

export type ActivationCheck = { checking: boolean; problem: string | null; ended: boolean; check: () => void };

export function useActivationPoll(account: KoboAccount): ActivationCheck {
  const { api: client } = useServices();
  const publish = usePublishAccount();
  const publishRef = useRef(publish);
  publishRef.current = publish;
  const [checking, setChecking] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [ended, setEnded] = useState(false);
  const inFlight = useRef<AbortController | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const live = useRef(true);
  const stopped = useRef(false);
  const pending = account.state === "pending";
  const id = account.id;

  const schedule = useRef<() => void>(() => undefined);
  const run = useCallback(async () => {
    if (inFlight.current || !live.current || stopped.current) return;
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    const controller = new AbortController();
    inFlight.current = controller;
    setChecking(true);
    try {
      const next = await api.poll(client, id, controller.signal);
      if (!live.current) return;
      setProblem(null);
      publishRef.current.account(next);
      if (next.state === "pending") schedule.current();
    } catch (error) {
      if (!live.current || (error instanceof DOMException && error.name === "AbortError")) return;
      if (isMissing(error) || failureKind(error) === "signed_out" || failureKind(error) === "account_changed") {
        stopped.current = true;
        setEnded(true);
        setProblem("This connection could not be checked. Reload the page to continue.");
        return;
      }
      setProblem("Could not reach Shelfarr. Retrying…");
      schedule.current();
    } finally {
      if (inFlight.current === controller) inFlight.current = null;
      if (live.current) setChecking(false);
    }
  }, [client, id]);

  schedule.current = () => {
    if (!live.current) return;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      timer.current = null;
      if (document.visibilityState === "hidden") return;
      void run();
    }, POLL_INTERVAL_MS);
  };

  useEffect(() => {
    live.current = true;
    if (!pending) return undefined;
    schedule.current();
    const resume = () => {
      if (document.visibilityState === "visible" && !timer.current && !inFlight.current) schedule.current();
    };
    document.addEventListener("visibilitychange", resume);
    return () => {
      live.current = false;
      document.removeEventListener("visibilitychange", resume);
      if (timer.current) clearTimeout(timer.current);
      timer.current = null;
      inFlight.current?.abort();
      inFlight.current = null;
    };
  }, [pending, run]);

  return { checking, problem, ended, check: () => void run() };
}
