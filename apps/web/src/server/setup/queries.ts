import { hashKey, useIsMutating, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
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

function useSetupWrite<Input, Answer>(write: (input: Input) => Promise<Answer>, answered: (answer: Answer) => SetupState | null) {
  const { guard } = useServices();
  const keys = useSetupKeys();
  const serverKeys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationKey: SETUP_WRITE,
    mutationFn: write,
    onSuccess: async (answer) => {
      if (!guard.isActive()) return;
      const next = answered(answer);
      const published = next ? hashKey(keys.step(next.step)) : null;
      await client.cancelQueries({ queryKey: keys.root });
      await client.invalidateQueries({ queryKey: keys.root, refetchType: "none" });
      if (next) client.setQueryData(keys.step(next.step), next);
      void client.refetchQueries({ queryKey: keys.root, type: "active", predicate: (query) => query.queryHash !== published });
      for (const queryKey of [serverKeys.settings, serverKeys.library, serverKeys.overview]) void client.invalidateQueries({ queryKey });
    },
  });
}

export function useSaveSetupStep(step: SetupStepId) {
  const { api } = useServices();
  return useSetupWrite(
    (values: setupApi.SetupValues) => setupApi.saveSetupStep(api, step, values),
    (answer) => (answer.kind === "saved" ? answer.saved.setup : null),
  );
}

export function useSkipSetup() {
  const { api } = useServices();
  return useSetupWrite(
    ({ step, exit }: { step: SetupStepId; exit: boolean }) => setupApi.skipSetup(api, step, exit),
    (answer) => answer.setup,
  );
}

export function useRestartSetup() {
  const { api } = useServices();
  return useSetupWrite(
    () => setupApi.restartSetup(api),
    (answer) => answer.setup,
  );
}

export function useSetupWriting(): boolean {
  return useIsMutating({ mutationKey: SETUP_WRITE }) > 0;
}
