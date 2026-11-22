import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ServerOverview, Session } from "../contract";
import { useSession } from "../queries";
import { useServices } from "../services";
import * as serverApi from "./api";
import type { ServerSettings, SettingGroup, TelegramChat } from "./contract";

export function useServerKeys() {
  const { keys } = useServices();
  const root = [...keys.root, "server"] as const;
  return {
    root,
    settings: [...root, "settings"] as const,
    library: [...root, "library"] as const,
    telegram: [...root, "telegram"] as const,
    overview: keys.serverOverview,
  };
}

export function useIsAdministrator(): boolean {
  return useSession().data?.admin !== undefined;
}

export type Capabilities = NonNullable<Session["capabilities"]>;

const NO_CAPABILITIES: Capabilities = { administrator: false, can_upload: false, single_sign_on: false, hardcover_personal_access: false };

export function useCapabilities(): Capabilities {
  const session = useSession().data;
  return session?.capabilities ?? { ...NO_CAPABILITIES, administrator: session?.admin !== undefined };
}

export function useServerSettings() {
  const { api } = useServices();
  const keys = useServerKeys();
  return useQuery({
    queryKey: keys.settings,
    queryFn: ({ signal }) => serverApi.serverSettings(api, signal),
    enabled: useIsAdministrator(),
    refetchOnWindowFocus: false,
    staleTime: 0,
  });
}

export function replaceGroup(settings: ServerSettings, group: SettingGroup): ServerSettings {
  return {
    ...settings,
    categories: settings.categories.map((category) => ({ ...category, groups: category.groups.map((entry) => (entry.id === group.id ? group : entry)) })),
  };
}

export function useSaveGroup(groupId: string) {
  const { api, guard } = useServices();
  const keys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (values: serverApi.SubmittedValues) => serverApi.saveGroup(api, groupId, values),
    onSuccess: async (answer) => {
      if (!guard.isActive() || answer.kind !== "saved") return;
      const changed = answer.saved.changed.length > 0;
      if (changed) await client.cancelQueries({ queryKey: keys.settings });
      client.setQueryData<ServerSettings>(keys.settings, (current) => (current ? replaceGroup(current, answer.saved.group) : current));
      if (changed) {
        void client.invalidateQueries({ queryKey: keys.settings });
        void client.invalidateQueries({ queryKey: keys.library });
      }
    },
  });
}

export function useProbe() {
  const { api } = useServices();
  return useMutation({ mutationFn: ({ probe, values }: { probe: string; values: serverApi.SubmittedValues }) => serverApi.runProbe(api, probe, values) });
}

export function useLibraryInventory(enabled: boolean) {
  const { api } = useServices();
  const keys = useServerKeys();
  return useQuery({ queryKey: keys.library, queryFn: ({ signal }) => serverApi.libraryInventory(api, signal), enabled, refetchOnWindowFocus: false });
}

export const FOLLOW_UP_READS_MS = [5_000, 15_000, 45_000] as const;

function readAgainLater(client: ReturnType<typeof useQueryClient>, queryKey: readonly unknown[]) {
  for (const delay of FOLLOW_UP_READS_MS) setTimeout(() => void client.invalidateQueries({ queryKey }), delay);
}

export function useLibrarySync() {
  const { api } = useServices();
  const keys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationFn: () => serverApi.syncLibrary(api),
    onSettled: () => {
      void client.invalidateQueries({ queryKey: keys.library });
      readAgainLater(client, keys.library);
    },
  });
}

export function useTelegramChats(enabled: boolean) {
  const { api } = useServices();
  const keys = useServerKeys();
  return useQuery({ queryKey: keys.telegram, queryFn: ({ signal }) => serverApi.telegramChats(api, signal), enabled, refetchOnWindowFocus: false });
}

export function useTelegramChatCommand() {
  const { api, guard } = useServices();
  const keys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (command: serverApi.TelegramChatCommand) => serverApi.telegramChatCommand(api, command),
    onSuccess: (answer) => {
      if (guard.isActive()) client.setQueryData<TelegramChat[]>(keys.telegram, answer.chats);
    },
  });
}

export function useOverviewAction() {
  const { api, guard } = useServices();
  const keys = useServerKeys();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (action: serverApi.OverviewAction) => serverApi.runOverviewAction(api, action),
    onSuccess: ({ overview }, action) => {
      if (!guard.isActive()) return;
      if (overview) client.setQueryData<ServerOverview>(keys.overview, overview);
      if (action === "health_check") readAgainLater(client, keys.overview);
    },
  });
}
