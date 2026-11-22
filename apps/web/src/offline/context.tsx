import { createContext, useContext } from "react";
import type { OfflineBoot } from "../contract";
import type { ConfirmedAccount, OfflineStore } from "./model";

export type Offline = {
  boot: OfflineBoot;
  store: OfflineStore;
  confirmation: ConfirmedAccount | null;
  connected: boolean;
  confirm: () => Promise<ConfirmedAccount>;
};

const OfflineContext = createContext<Offline | null>(null);

export const OfflineProvider = OfflineContext.Provider;

export function useOffline(): Offline | null {
  return useContext(OfflineContext);
}

export function confirmationFrom(account: string, expiresIn: number | undefined, now: number): ConfirmedAccount | null {
  return expiresIn === undefined ? null : { account, confirmedAt: now, validForMs: expiresIn * 1000 };
}

const CHANNEL = "shelfarr-go-preview-offline";
const listeners = new Set<() => void>();
let channel: BroadcastChannel | null = null;

function shared(): BroadcastChannel | null {
  if (typeof BroadcastChannel !== "function") return null;
  if (!channel) {
    channel = new BroadcastChannel(CHANNEL);
    channel.onmessage = () => {
      for (const listener of [...listeners]) listener();
    };
  }
  return channel;
}

export function announceChange(): void {
  shared()?.postMessage("changed");
}

export function onChange(listener: () => void): () => void {
  shared();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
