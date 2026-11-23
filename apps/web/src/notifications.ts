import { useMutation, useQuery, type QueryClient } from "@tanstack/react-query";
import type { NotificationChange } from "./contract";
import { useServices, type Services } from "./services";

const waitingForFirstSession = new WeakSet<QueryClient>();

function readSessionAgain({ keys, guard, queryClient }: Services) {
  if (!guard.isActive()) return;
  const filter = { queryKey: keys.session, exact: true };
  const first = queryClient.getQueryState(keys.session);
  if (first?.data !== undefined || first?.fetchStatus !== "fetching") {
    void queryClient.invalidateQueries(filter);
    return;
  }
  if (waitingForFirstSession.has(queryClient)) return;
  waitingForFirstSession.add(queryClient);
  void queryClient
    .refetchQueries(filter, { cancelRefetch: false })
    .then(() => {
      waitingForFirstSession.delete(queryClient);
      if (guard.isActive()) return queryClient.invalidateQueries(filter);
    });
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
  const services = useServices();
  const { api, keys, guard, queryClient } = services;
  return useMutation({
    mutationFn: (command: NotificationCommand): Promise<NotificationChange> => {
      if (command.kind === "read") return api.markNotificationRead(command.id);
      if (command.kind === "read_all") return api.markNotificationsRead(command.through);
      return api.clearNotifications(command.through);
    },
    onSettled: () => {
      if (!guard.isActive()) return;
      void queryClient.invalidateQueries({ queryKey: keys.notifications });
      readSessionAgain(services);
    },
  });
}
