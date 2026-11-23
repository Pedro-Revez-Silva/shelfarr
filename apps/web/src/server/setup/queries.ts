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

type Written = { step: SetupStepId | null; next: SetupState | null };

function useSetupWrite<Input, Answer>(write: (input: Input) => Promise<Answer>, written: (input: Input, answer: Answer) => Written) {
  const { guard } = useServices();
  const keys = useSetupKeys();
  const serverKeys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationKey: SETUP_WRITE,
    mutationFn: write,
    onSuccess: async (answer, input) => {
      if (!guard.isActive()) return;
      const { step, next } = written(input, answer);
      await client.cancelQueries({ queryKey: keys.root });
      await client.invalidateQueries({ queryKey: keys.root, refetchType: "none" });
      if (next) client.setQueryData(keys.step(next.step), next);
      const current = new Set([step, next?.step]);
      void client.refetchQueries({ queryKey: keys.root, type: "active", predicate: (query) => !current.has((query.state.data as SetupState | undefined)?.step ?? null) });
      for (const queryKey of [serverKeys.settings, serverKeys.library, serverKeys.overview]) void client.invalidateQueries({ queryKey });
    },
  });
}

export function useSaveSetupStep(step: SetupStepId) {
  const { api } = useServices();
  return useSetupWrite(
    (values: setupApi.SetupValues) => setupApi.saveSetupStep(api, step, values),
    (_values, answer) => ({ step, next: answer.kind === "saved" ? answer.saved.setup : null }),
  );
}

export function useSkipSetup() {
  const { api } = useServices();
  return useSetupWrite(
    ({ step, exit }: { step: SetupStepId; exit: boolean }) => setupApi.skipSetup(api, step, exit),
    ({ step }, answer) => ({ step, next: answer.setup }),
  );
}

export function useRestartSetup() {
  const { api } = useServices();
  return useSetupWrite(
    () => setupApi.restartSetup(api),
    (_input, answer) => ({ step: null, next: answer.setup }),
  );
}

export function useSetupWriting(): boolean {
  return useIsMutating({ mutationKey: SETUP_WRITE }) > 0;
}
