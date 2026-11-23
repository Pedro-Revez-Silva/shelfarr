import { useIsMutating, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { failureKind, isLockingFailure } from "../../api/errors";
import { describeWriteFailure } from "../../components/accountFields";
import { useServices } from "../../services";
import * as api from "./api";
import { isHardcoverPage, type HardcoverDevice, type HardcoverState } from "./contract";

export const MIN_POLL_SECONDS = 5;

export function useHardcoverKeys() {
  const { keys } = useServices();
  return useMemo(() => {
    const root = [...keys.root, "hardcover"] as const;
    return { root, state: [...root, "state"] as const, writes: [...root, "write"] as const };
  }, [keys]);
}

export function useHardcover() {
  const { api: client, mode } = useServices();
  return useQuery({
    queryKey: useHardcoverKeys().state,
    queryFn: ({ signal }) => api.state(client, signal),
    enabled: mode === "rails",
    refetchOnWindowFocus: false,
    staleTime: 0,
    retry: (count, error) => failureKind(error) !== "not_found" && count < 2,
  });
}

export function usePublishHardcover() {
  const { guard } = useServices();
  const keys = useHardcoverKeys();
  const client = useQueryClient();
  return useMemo(
    () => ({
      active: () => guard.isActive(),
      state: (state: HardcoverState) => {
        if (!guard.isActive()) return;
        void client.cancelQueries({ queryKey: keys.state, exact: true }, { revert: false, silent: true });
        client.setQueryData(keys.state, state);
      },
      reread: () => {
        if (guard.isActive()) void client.invalidateQueries({ queryKey: keys.state, exact: true });
      },
    }),
    [client, guard, keys],
  );
}

export function useHardcoverBusy(): boolean {
  return useIsMutating({ mutationKey: useHardcoverKeys().writes }) > 0;
}

export function useHardcoverWriting(): () => boolean {
  const client = useQueryClient();
  const writes = useHardcoverKeys().writes;
  return useCallback(() => client.isMutating({ mutationKey: writes }) > 0, [client, writes]);
}

export function useHardcoverWrite<Input, Answer extends { kind: string; hardcover?: HardcoverState }>(write: (input: Input) => Promise<Answer>) {
  const publish = usePublishHardcover();
  const keys = useHardcoverKeys();
  return useMutation({
    mutationKey: keys.writes,
    mutationFn: write,
    gcTime: 0,
    onSuccess: (answer) => {
      if (answer.hardcover) publish.state(answer.hardcover);
    },
    onSettled: (answer) => {
      if (answer?.kind !== "redirect") publish.reread();
    },
  });
}

export function hardcoverFailure(error: unknown, uncertain: string): string {
  if (failureKind(error) === "not_found") return "Hardcover connections are not available on this server. Nothing was changed.";
  return describeWriteFailure(error, uncertain);
}

export const external = {
  open(url: string): boolean {
    if (!isHardcoverPage(url)) return false;
    const link = document.createElement("a");
    link.href = url;
    link.rel = "noreferrer";
    link.referrerPolicy = "no-referrer";
    link.click();
    return true;
  },
};

export type CodeOutcome = { tone: "success" | "error"; message: string };
export type CodeCheck = { checking: boolean; problem: string | null; check: () => void };

export function useCodePoll(device: HardcoverDevice, onEnd: (outcome: CodeOutcome) => void): CodeCheck {
  const { api: client } = useServices();
  const publish = usePublishHardcover();
  const queryClient = useQueryClient();
  const writes = useHardcoverKeys().writes;
  const code = device.user_code;
  const { mutateAsync: checkCode } = useMutation({ mutationKey: writes, mutationFn: (signal: AbortSignal) => api.pollCode(client, code, signal), gcTime: 0 });
  const onEndRef = useRef(onEnd);
  onEndRef.current = onEnd;
  const [checking, setChecking] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const inFlight = useRef<AbortController | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const live = useRef(true);
  const delay = Math.max(device.interval, MIN_POLL_SECONDS) * 1000;
  const schedule = useRef<() => void>(() => undefined);

  const run = useCallback(async () => {
    if (inFlight.current || !live.current) return;
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    if (queryClient.isMutating({ mutationKey: writes }) > 0) {
      schedule.current();
      return;
    }
    const controller = new AbortController();
    inFlight.current = controller;
    setChecking(true);
    try {
      const answer = await checkCode(controller.signal);
      if (!live.current || !publish.active()) return;
      setProblem(null);
      publish.state(answer.hardcover);
      if ("kind" in answer) {
        onEndRef.current({ tone: "error", message: answer.message });
      } else if (answer.status === "approved") {
        onEndRef.current({ tone: "success", message: answer.message ?? "Hardcover account connected." });
      } else if (answer.status === "failed") {
        onEndRef.current({ tone: "error", message: answer.message ?? "Hardcover sign-in ended. Start again." });
      } else {
        schedule.current();
      }
      publish.reread();
    } catch (error) {
      if (!live.current || (error instanceof DOMException && error.name === "AbortError")) return;
      if (isLockingFailure(failureKind(error)) || failureKind(error) === "not_found") {
        setProblem("This sign-in can't be checked here any more. Reload the page to continue.");
        return;
      }
      setProblem("Could not reach Shelfarr. Retrying…");
      schedule.current();
    } finally {
      if (inFlight.current === controller) inFlight.current = null;
      if (live.current) setChecking(false);
    }
  }, [checkCode, publish, queryClient, writes]);

  schedule.current = () => {
    if (!live.current) return;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => {
      timer.current = null;
      if (document.visibilityState === "hidden") return;
      void run();
    }, delay);
  };

  useEffect(() => {
    live.current = true;
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
  }, [code, delay, run]);

  return { checking, problem, check: () => void run() };
}
