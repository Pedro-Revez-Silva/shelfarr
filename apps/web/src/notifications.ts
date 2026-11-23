import { useMutation, useQuery } from "@tanstack/react-query";
import type { NotificationChange, Session } from "./contract";
import { useServices, type Services } from "./services";

function adoptUnreadCount({ keys, guard, queryClient }: Services, unread: number) {
  const filter = { queryKey: keys.session, exact: true };
  void queryClient.cancelQueries(filter).then(() => {
    if (!guard.isActive()) return;
    const current = queryClient.getQueryData<Session>(keys.session);
    const bell = current?.notifications;
    if (current && bell && bell.unread !== unread) queryClient.setQueryData<Session>(keys.session, { ...current, notifications: { ...bell, unread } });
    return queryClient.invalidateQueries(filter);
  });
}

export function useNotifications() {
  const services = useServices();
  return useQuery({
    queryKey: services.keys.notifications,
    queryFn: async ({ signal }) => {
      const list = await services.api.notifications(signal);
      adoptUnreadCount(services, list.unread);
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
    onSuccess: (answer) => adoptUnreadCount(services, answer.unread),
    onSettled: () => {
      if (!guard.isActive()) return;
      void queryClient.invalidateQueries({ queryKey: keys.notifications });
    },
  });
}
