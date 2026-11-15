import { ApiError } from "./errors";

export type GuardState = { status: "active" } | { status: "signed_out" } | { status: "account_changed" };

type Listener = () => void;

export class AccountGuard {
  readonly account: string;
  private state: GuardState = { status: "active" };
  private readonly listeners = new Set<Listener>();
  private readonly validations = new Set<Promise<void>>();

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

  track(validation: Promise<void>): Promise<void> {
    const tracked = validation.finally(() => {
      this.validations.delete(tracked);
    });
    this.validations.add(tracked);
    return tracked;
  }

  hasPendingValidation(): boolean {
    return this.validations.size > 0;
  }

  async settled(): Promise<void> {
    while (this.validations.size > 0) await Promise.all([...this.validations]);
  }

  assertActive(): void {
    if (this.state.status === "signed_out") throw new ApiError("signed_out", "Your session ended", 401);
    if (this.state.status === "account_changed") throw new ApiError("account_changed", "The signed-in account changed", 401);
  }
}
