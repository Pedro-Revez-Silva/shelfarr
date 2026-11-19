import { ApiError } from "./errors";

export type GuardState = { status: "active" } | { status: "signed_out" } | { status: "account_changed" } | { status: "access_changed" };
export type LockReason = Exclude<GuardState["status"], "active">;
export type Trust = "trusted" | "checking" | "unverified";

type Listener = () => void;

export class AccountGuard {
  readonly account: string;
  private state: GuardState = { status: "active" };
  private trustState: Trust = "trusted";
  private currentGeneration = 0;
  private readonly listeners = new Set<Listener>();
  private readonly trustListeners = new Set<Listener>();
  private readonly settleWaiters = new Set<() => void>();

  constructor(account: string) {
    this.account = account;
  }

  getState = (): GuardState => this.state;

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  getTrust = (): Trust => this.trustState;

  subscribeTrust = (listener: Listener): (() => void) => {
    this.trustListeners.add(listener);
    return () => {
      this.trustListeners.delete(listener);
    };
  };

  isActive(): boolean {
    return this.state.status === "active";
  }

  get trust(): Trust {
    return this.trustState;
  }

  get generation(): number {
    return this.currentGeneration;
  }

  lock(reason: LockReason): void {
    if (!this.isActive()) return;
    this.state = { status: reason };
    this.releaseWaiters();
    for (const listener of [...this.listeners]) listener();
  }

  invalidate(): number {
    if (!this.isActive()) return this.currentGeneration;
    this.currentGeneration += 1;
    this.trustState = "checking";
    this.trustChanged();
    return this.currentGeneration;
  }

  finishCheck(generation: number, confirmed: boolean): void {
    if (generation !== this.currentGeneration || !this.isActive()) return;
    this.trustState = confirmed ? "trusted" : "unverified";
    this.releaseWaiters();
    this.trustChanged();
  }

  async untilSettled(): Promise<boolean> {
    while (this.trustState === "checking" && this.isActive()) {
      await new Promise<void>((resolve) => this.settleWaiters.add(resolve));
    }
    return this.trustState === "trusted";
  }

  assertActive(): void {
    if (this.state.status === "signed_out") throw new ApiError("signed_out", "Your session ended", 401);
    if (this.state.status === "account_changed" || this.state.status === "access_changed") throw new ApiError("account_changed", "The signed-in account changed", 401);
  }

  private trustChanged(): void {
    for (const listener of [...this.trustListeners]) listener();
  }

  private releaseWaiters(): void {
    for (const resolve of [...this.settleWaiters]) resolve();
    this.settleWaiters.clear();
  }
}
