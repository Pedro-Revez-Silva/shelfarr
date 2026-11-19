import { createContext, useContext } from "react";
import type { LockReason } from "../api/account-guard";

export type GoSession = {
  signOut: () => Promise<boolean>;
  recover: (reason: LockReason) => void;
};

const GoSessionContext = createContext<GoSession | null>(null);

export const GoSessionProvider = GoSessionContext.Provider;

export function useGoSession(): GoSession | null {
  return useContext(GoSessionContext);
}
