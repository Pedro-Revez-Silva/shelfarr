import type { Locator, ProgressPlace } from "../contract";
import { pendingUpload, type OfflineStore } from "./model";

export type DeviceSaveState = { kind: "idle" } | { kind: "kept" } | { kind: "failed" } | { kind: "stopped" } | { kind: "replaced" };

const WRITE_DELAY_MS = 300;

export class DevicePlaces {
  private state: DeviceSaveState = { kind: "idle" };
  private readonly listeners = new Set<() => void>();
  private pending: { place: { asset_id: string; locator: Locator }; at: number } | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private writing: Promise<void> = Promise.resolve();
  private stopped = false;
  private latest = 0;
  private readonly store: OfflineStore;
  private readonly account: string;
  private readonly id: string;
  private readonly onRefused: () => void;
  private readonly onKept: () => void;
  private readonly now: () => number;

  constructor(store: OfflineStore, account: string, id: string, onRefused: () => void, now: () => number = Date.now, onKept: () => void = () => undefined) {
    this.store = store;
    this.account = account;
    this.id = id;
    this.onRefused = onRefused;
    this.now = now;
    this.onKept = onKept;
  }

  getState = (): DeviceSaveState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  record = (place: ProgressPlace, at: number = this.now()): void => {
    if (this.stopped || !place.locator) return;
    this.pending = { place: { asset_id: place.asset_id, locator: place.locator }, at };
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.flush();
    }, WRITE_DELAY_MS);
  };

  flush(): Promise<void> {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const next = this.pending;
    this.pending = null;
    if (!next || this.stopped) return this.writing;
    const observedAt = Math.max(next.at, this.latest + 1);
    this.latest = observedAt;
    this.writing = this.writing.then(async () => {
      if (this.stopped) return;
      try {
        const edition = { replaced: false };
        const outcome = await this.store.updateBook(
          this.account,
          this.id,
          (book) => {
            edition.replaced = book.asset.id !== next.place.asset_id;
            const stored = book.devicePlace;
            if (edition.replaced || (stored?.asset_id === next.place.asset_id && Date.parse(stored.observedAt) >= observedAt)) return null;
            return {
              ...book,
              devicePlace: {
                asset_id: next.place.asset_id,
                locator: next.place.locator,
                observedAt: new Date(observedAt).toISOString(),
                recordedAt: this.now(),
                basedOn: book.accountPlace && book.accountPlace.learnedAt < next.at ? book.accountPlace.version : 0,
                upload: pendingUpload(),
              },
            };
          },
          this.now(),
        );
        if (outcome === "refused") {
          this.stop();
          this.onRefused();
        } else if (edition.replaced) {
          this.stop();
          this.set({ kind: "replaced" });
        } else {
          this.set({ kind: "kept" });
          if (outcome === "updated") this.onKept();
        }
      } catch {
        this.set({ kind: "failed" });
      }
    });
    return this.writing;
  }

  stop(): void {
    this.stopped = true;
    this.pending = null;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.set({ kind: "stopped" });
  }

  private set(state: DeviceSaveState): void {
    this.state = state;
    for (const listener of [...this.listeners]) listener();
  }
}
