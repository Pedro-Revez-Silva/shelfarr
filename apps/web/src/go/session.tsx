import { createContext, useContext } from "react";

export type GoSession = {
  signOut: () => Promise<boolean>;
  recover: (reason: "signed_out" | "account_changed") => void;
};

const GoSessionContext = createContext<GoSession | null>(null);

export const GoSessionProvider = GoSessionContext.Provider;

export function useGoSession(): GoSession | null {
  return useContext(GoSessionContext);
}
