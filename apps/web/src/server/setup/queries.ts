import { useIsMutating, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useServices } from "../../services";
import { useIsAdministrator, useServerKeys } from "../queries";
import * as setupApi from "./api";
import type { SetupState, SetupStepId } from "./contract";

const SETUP_FRESH_MS = 60_000;
const SETUP_WRITE = ["setup-write"] as const;

export function useSetupKeys() {
  const root = [...useServerKeys().root, "setup"] as const;
  return { root, step: (step: string | undefined) => [...root, step ?? ""] as const };
}

export function useSetupState(step: string | undefined) {
  const { api } = useServices();
  const keys = useSetupKeys();
  return useQuery({
    queryKey: keys.step(step),
    queryFn: ({ signal }) => setupApi.setupState(api, step, signal),
    enabled: useIsAdministrator(),
    refetchOnWindowFocus: false,
    staleTime: SETUP_FRESH_MS,
  });
}

export function useSetupMoves() {
  const { guard } = useServices();
  const keys = useSetupKeys();
  const serverKeys = useServerKeys();
  const client = useQueryClient();
  return (next: SetupState | null) => {
    if (!guard.isActive()) return;
    client.removeQueries({ queryKey: keys.root });
    if (next) client.setQueryData(keys.step(next.step), next);
    void client.invalidateQueries({ queryKey: serverKeys.settings });
    void client.invalidateQueries({ queryKey: serverKeys.library });
    void client.invalidateQueries({ queryKey: serverKeys.overview });
  };
}

export function useSaveSetupStep(step: SetupStepId) {
  const { api } = useServices();
  return useMutation({ mutationKey: SETUP_WRITE, mutationFn: (values: setupApi.SetupValues) => setupApi.saveSetupStep(api, step, values) });
}

export function useSkipSetup() {
  const { api } = useServices();
  return useMutation({ mutationKey: SETUP_WRITE, mutationFn: ({ step, exit }: { step: SetupStepId; exit: boolean }) => setupApi.skipSetup(api, step, exit) });
}

export function useRestartSetup() {
  const { api } = useServices();
  return useMutation({ mutationKey: SETUP_WRITE, mutationFn: () => setupApi.restartSetup(api) });
}

export function useSetupWriting(): boolean {
  return useIsMutating({ mutationKey: SETUP_WRITE }) > 0;
}
