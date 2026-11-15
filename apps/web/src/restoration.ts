import { useCallback, useEffect, useRef } from "react";
import { z } from "zod";

const HISTORY_KEY = "shelfarrLibrary";
export const MAX_RESTORED_PAGES = 20;

const savedSchema = z.object({
  pages: z.number().int().min(1).max(MAX_RESTORED_PAGES),
  scrollY: z.number().min(0).max(10_000_000),
});
export type SavedList = z.infer<typeof savedSchema>;

export function readSavedList(): SavedList | null {
  const state: unknown = window.history.state;
  if (typeof state !== "object" || state === null || !(HISTORY_KEY in state)) return null;
  const parsed = savedSchema.safeParse((state as Record<string, unknown>)[HISTORY_KEY]);
  return parsed.success ? parsed.data : null;
}

export function writeSavedList(saved: SavedList): void {
  const state: unknown = window.history.state;
  const base = typeof state === "object" && state !== null ? state : {};
  window.history.replaceState({ ...base, [HISTORY_KEY]: saved }, "");
}

type Restoration = {
  isSuccess: boolean;
  pageCount: number;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  fetchNextPage: () => unknown;
  isListLocation: () => boolean;
};

export function useListRestoration({ isSuccess, pageCount, hasNextPage, isFetchingNextPage, fetchNextPage, isListLocation }: Restoration) {
  const target = useRef<SavedList | null | undefined>(undefined);
  if (target.current === undefined) target.current = readSavedList();
  const restoring = useRef(target.current !== null);
  const pages = useRef(pageCount);
  pages.current = pageCount;

  const persist = useCallback(() => {
    if (restoring.current || !isListLocation()) return;
    writeSavedList({ pages: Math.max(1, Math.min(pages.current, MAX_RESTORED_PAGES)), scrollY: Math.round(window.scrollY) });
  }, [isListLocation]);

  useEffect(() => {
    const saved = target.current;
    if (!restoring.current || !saved || !isSuccess) return;
    if (pageCount < saved.pages && hasNextPage) {
      if (!isFetchingNextPage) void fetchNextPage();
      return;
    }
    restoring.current = false;
    window.scrollTo(0, saved.scrollY);
  }, [isSuccess, pageCount, hasNextPage, isFetchingNextPage, fetchNextPage]);

  useEffect(() => {
    let frame = 0;
    const onScroll = () => {
      if (frame) return;
      frame = window.requestAnimationFrame(() => {
        frame = 0;
        persist();
      });
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("pagehide", persist);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("pagehide", persist);
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, [persist]);

  useEffect(() => {
    persist();
  }, [pageCount, persist]);

  return persist;
}
