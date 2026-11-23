import { useMutation, useQuery } from "@tanstack/react-query";
import type { NotificationChange } from "./contract";
import { useServices, type Services } from "./services";

function readSessionAgain({ keys, guard, queryClient }: Services) {
  if (guard.isActive()) void queryClient.invalidateQueries({ queryKey: keys.session, exact: true });
}

export function useNotifications() {
  const services = useServices();
  return useQuery({
    queryKey: services.keys.notifications,
    queryFn: async ({ signal }) => {
      const list = await services.api.notifications(signal);
      readSessionAgain(services);
      return list;
    },
  });
}

export type NotificationCommand = { kind: "read"; id: string } | { kind: "read_all"; through: string } | { kind: "clear"; through: string };

export function useNotificationCommand() {
  const { api, keys, guard, queryClient } = useServices();
  return useMutation({
    mutationFn: (command: NotificationCommand): Promise<NotificationChange> => {
      if (command.kind === "read") return api.markNotificationRead(command.id);
      if (command.kind === "read_all") return api.markNotificationsRead(command.through);
      return api.clearNotifications(command.through);
    },
    onSettled: () => {
      if (guard.isActive()) void queryClient.invalidateQueries({ queryKey: keys.notifications });
    },
  });
}
