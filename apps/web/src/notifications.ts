import { useMutation, useQuery } from "@tanstack/react-query";
import { useEffect, useRef } from "react";
import type { NotificationChange } from "./contract";
import { useSession } from "./queries";
import { useServices } from "./services";

export function useNotifications() {
  const { api, keys, queryClient } = useServices();
  const list = useQuery({
    queryKey: keys.notifications,
    queryFn: ({ signal }) => api.notifications(signal),
  });
  const bell = useSession().data?.notifications?.unread;
  const unread = list.data?.unread;
  const fetchedAt = list.dataUpdatedAt;
  const reconciled = useRef(0);
  useEffect(() => {
    if (unread === undefined || bell === undefined || bell === unread || reconciled.current === fetchedAt) return;
    reconciled.current = fetchedAt;
    void queryClient.invalidateQueries({ queryKey: keys.session, exact: true });
  }, [bell, unread, fetchedAt, queryClient, keys.session]);
  return list;
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
      if (!guard.isActive()) return;
      void queryClient.invalidateQueries({ queryKey: keys.notifications });
      void queryClient.invalidateQueries({ queryKey: keys.session, exact: true });
    },
  });
}
