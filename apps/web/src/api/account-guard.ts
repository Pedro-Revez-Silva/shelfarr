import { ApiError } from "./errors";

export type GuardState = { status: "active" } | { status: "signed_out" } | { status: "account_changed" };

type Listener = () => void;

export class AccountGuard {
  readonly account: string;
  private state: GuardState = { status: "active" };
  private readonly listeners = new Set<Listener>();

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

  isActive(): boolean {
    return this.state.status === "active";
  }

  lock(reason: "signed_out" | "account_changed"): void {
    if (!this.isActive()) return;
    this.state = { status: reason };
    for (const listener of [...this.listeners]) listener();
  }

  assertActive(): void {
    if (this.state.status === "signed_out") throw new ApiError("signed_out", "Your session ended", 401);
    if (this.state.status === "account_changed") throw new ApiError("account_changed", "The signed-in account changed", 401);
  }
}
