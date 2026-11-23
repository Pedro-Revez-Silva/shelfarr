import { createContext, useContext } from "react";
import type { OfflineBoot } from "../contract";
import type { ConfirmedAccount, OfflineStore } from "./model";
import { cookieValue } from "./store";
import type { SyncRunner } from "./sync";

export type Offline = {
  boot: OfflineBoot;
  store: OfflineStore;
  confirmation: ConfirmedAccount | null;
  connected: boolean;
  confirm: () => Promise<ConfirmedAccount>;
  sync: SyncRunner | null;
};

const OfflineContext = createContext<Offline | null>(null);

export const OfflineProvider = OfflineContext.Provider;

export function useOffline(): Offline | null {
  return useContext(OfflineContext);
}

type Confirmable = { account: string; offline_expires_in?: number | undefined; offline_continuity?: string | undefined };

export function confirmationFrom({ account, offline_expires_in: expiresIn, offline_continuity: continuity }: Confirmable, now: number): ConfirmedAccount | null {
  if (expiresIn === undefined) return null;
  const confirmation: ConfirmedAccount = { account, confirmedAt: now, validForMs: expiresIn * 1000 };
  return continuity === undefined ? confirmation : { ...confirmation, continuity };
}

export function continuityOf(boot: OfflineBoot): string | null {
  return boot.continuity_cookie === undefined ? null : cookieValue(document.cookie, boot.continuity_cookie);
}

type CookieChange = Event & { changed?: { name: string }[]; deleted?: { name: string }[] };

export function onContinuityChange(boot: OfflineBoot | undefined, listener: () => void): () => void {
  const name = boot?.continuity_cookie;
  const cookies = (globalThis as { cookieStore?: EventTarget }).cookieStore;
  if (name === undefined || !cookies) return () => undefined;
  const changed = (event: Event) => {
    const { changed: set = [], deleted = [] } = event as CookieChange;
    if ([...set, ...deleted].some((cookie) => cookie.name === name)) listener();
  };
  cookies.addEventListener("change", changed);
  return () => cookies.removeEventListener("change", changed);
}

export async function steady<T>(boot: OfflineBoot, read: () => Promise<T>): Promise<T> {
  for (;;) {
    const before = continuityOf(boot);
    const value = await read();
    if (continuityOf(boot) === before) return value;
  }
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
