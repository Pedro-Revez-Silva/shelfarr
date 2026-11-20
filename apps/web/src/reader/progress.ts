import type { AccountGuard } from "../api/account-guard";
import type { ProgressAnswer } from "../api/client";
import { isApiError } from "../api/errors";
import type { ProgressPlace, ProgressRequest, StoredProgress } from "../contract";
import { plausibleObservedAt, samePlace } from "./shared";

export type SaveState =
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "saved" }
  | { kind: "uncertain" }
  | { kind: "token_refused" }
  | { kind: "rejected"; message: string }
  | { kind: "remote"; remote: StoredProgress }
  | { kind: "conflict"; remote: StoredProgress | null; local: ProgressPlace }
  | { kind: "stopped" };

export type ProgressWriter = (body: ProgressRequest, options: { keepalive: boolean }) => Promise<ProgressAnswer>;

type Observation = { place: ProgressPlace; observedAt: string };

export type ProgressSessionOptions = {
  write: ProgressWriter;
  guard: AccountGuard;
  assets: ReadonlySet<string>;
  saved: StoredProgress | null;
  confirmed?: (progress: StoredProgress) => void;
  now?: () => number;
  uuid?: () => string;
  delayMs?: number;
};

const SEND_DELAY_MS = 1500;
const MAX_REBASES = 5;

function randomUuid(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function placeOf(source: ProgressPlace | ProgressRequest | StoredProgress): ProgressPlace {
  if (source.locator) return { asset_id: source.asset_id, locator: source.locator };
  return { asset_id: source.asset_id, position_seconds: source.position_seconds ?? 0 };
}

export class ProgressSession {
  private state: SaveState = { kind: "idle" };
  private readonly listeners = new Set<() => void>();
  private readonly options: Required<Omit<ProgressSessionOptions, "saved" | "confirmed">>;
  private readonly confirmed: ((progress: StoredProgress) => void) | undefined;
  private queued: Observation | null = null;
  private inflight: ProgressRequest | null = null;
  private held: ProgressRequest | null = null;
  private version: number;
  private latestActivity: number | null = null;
  private rebases = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;

  constructor(options: ProgressSessionOptions) {
    this.options = {
      write: options.write,
      guard: options.guard,
      assets: options.assets,
      now: options.now ?? (() => Date.now()),
      uuid: options.uuid ?? randomUuid,
      delayMs: options.delayMs ?? SEND_DELAY_MS,
    };
    this.version = options.saved?.version ?? 0;
    this.confirmed = options.confirmed;
  }

  getState = (): SaveState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  record(place: ProgressPlace, at: number = this.options.now()): void {
    if (!this.writable()) return;
    this.queued = { place, observedAt: this.stamp(at) };
    if (this.state.kind === "conflict") {
      this.set({ kind: "conflict", remote: this.state.remote, local: place });
      return;
    }
    this.schedule(this.options.delayMs);
  }

  flush(options: { keepalive?: boolean } = {}): void {
    this.clearTimer();
    if (!this.writable() || this.held || this.state.kind === "conflict") return;
    const next = this.queued;
    if (!next || this.inflight) return;
    this.queued = null;
    void this.send({ ...next.place, observed_at: next.observedAt, expected_version: this.version, client_mutation_id: this.options.uuid() }, options.keepalive ?? false);
  }

  retry(): void {
    if (!this.writable() || this.inflight || !this.held) return;
    const request = this.held;
    this.held = null;
    void this.send(request, false);
  }

  keepLocal(): void {
    if (!this.writable() || this.state.kind !== "conflict") return;
    const { remote, local } = this.state;
    this.queued = null;
    this.rebases = 0;
    void this.send({ ...local, observed_at: this.stamp(this.options.now()), expected_version: remote?.version ?? 0, client_mutation_id: this.options.uuid(), resolve_conflict: true }, false);
  }

  useRemote(): StoredProgress | null {
    if (this.state.kind !== "conflict" && this.state.kind !== "remote") return null;
    const remote = this.state.remote;
    this.queued = null;
    this.version = Math.max(this.version, remote?.version ?? 0);
    this.set({ kind: "idle" });
    return remote;
  }

  get unsaved(): boolean {
    return this.writable() && (this.queued !== null || this.inflight !== null || this.held !== null || this.state.kind === "conflict");
  }

  async drain(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    this.flush();
    while (this.writable() && (this.inflight || (this.queued && !this.held && this.state.kind !== "conflict")) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
      if (!this.inflight) this.flush();
    }
  }

  dismissRemote(): void {
    if (this.state.kind === "remote") this.set({ kind: "idle" });
  }

  stop(): void {
    this.stopped = true;
    this.clearTimer();
    this.queued = null;
    this.set({ kind: "stopped" });
  }

  private writable(): boolean {
    return !this.stopped && this.options.guard.isActive();
  }

  private stamp(at: number): string {
    const previous = this.latestActivity;
    const value = previous !== null && previous >= at ? previous + 1 : at;
    this.latestActivity = value;
    return new Date(value).toISOString();
  }

  private schedule(delay: number): void {
    if (this.timer || this.inflight || this.held) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, delay);
  }

  private clearTimer(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private async send(request: ProgressRequest, keepalive: boolean): Promise<void> {
    if (!this.writable()) return;
    this.inflight = request;
    this.set({ kind: "saving" });
    let answer: ProgressAnswer;
    try {
      answer = await this.options.write(request, { keepalive });
    } catch (error) {
      this.inflight = null;
      if (this.writable()) this.failed(request, error);
      return;
    }
    this.inflight = null;
    if (!this.writable()) return;
    if (answer.kind === "saved") this.accepted(answer.progress);
    else this.reconcile(request, answer.progress);
  }

  private accepted(progress: StoredProgress): void {
    this.version = Math.max(this.version, progress.version);
    this.rebases = 0;
    this.confirmed?.(progress);
    this.set({ kind: "saved" });
    this.continueQueue();
  }

  private reconcile(request: ProgressRequest, remote: StoredProgress | null): void {
    const now = this.options.now();
    const localTime = plausibleObservedAt(request.observed_at, now);
    const remoteTime = remote ? plausibleObservedAt(remote.observed_at, now) : null;
    const mappable = !remote || this.options.assets.has(remote.asset_id);
    if (this.rebases < MAX_REBASES && mappable && localTime !== null && !request.resolve_conflict) {
      if (!remote || (remoteTime !== null && localTime > remoteTime)) {
        this.rebases += 1;
        void this.send({ ...request, expected_version: remote?.version ?? 0, client_mutation_id: this.options.uuid() }, false);
        return;
      }
      if (remoteTime !== null && (remoteTime > localTime || samePlace(request, remote))) {
        this.rebases = 0;
        this.version = Math.max(this.version, remote.version);
        const later = this.queued && (plausibleObservedAt(this.queued.observedAt, now) ?? 0) > remoteTime;
        if (!later) this.queued = null;
        this.set(samePlace(request, remote) ? { kind: "saved" } : { kind: "remote", remote });
        this.continueQueue();
        return;
      }
    }
    this.rebases = 0;
    const local = this.queued?.place ?? placeOf(request);
    this.queued = null;
    this.set({ kind: "conflict", remote, local });
  }

  private failed(request: ProgressRequest, error: unknown): void {
    if (isApiError(error)) {
      if (error.kind === "signed_out" || error.kind === "account_changed") {
        this.stop();
        return;
      }
      if (error.kind === "csrf") {
        this.held = request;
        this.set({ kind: "token_refused" });
        return;
      }
      if (error.kind === "invalid" || error.kind === "not_found") {
        this.set({ kind: "rejected", message: error.message });
        this.continueQueue();
        return;
      }
    }
    this.held = request;
    this.set({ kind: "uncertain" });
  }

  private continueQueue(): void {
    if (this.queued && this.state.kind !== "conflict") this.schedule(0);
  }

  private set(state: SaveState): void {
    this.state = state;
    for (const listener of [...this.listeners]) listener();
  }
}

export function describePlace(place: ProgressPlace | StoredProgress | null, clock: (seconds: number) => string): string {
  if (!place) return "no saved place";
  if (typeof place.position_seconds === "number") return clock(place.position_seconds);
  const locations = place.locator?.locations;
  const page = locations?.position;
  if (/^(application\/pdf|image\/)/.test(place.locator?.type ?? "") && typeof page === "number") return `page ${page}`;
  const total = locations?.totalProgression;
  return typeof total === "number" ? `${Math.round(total * 100)}% through` : "a different place";
}

export function clockTime(seconds: number): string {
  if (!Number.isFinite(seconds)) return "—";
  const value = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const rest = String(value % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}
