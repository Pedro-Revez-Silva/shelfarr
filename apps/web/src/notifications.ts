import { useMutation, useQuery } from "@tanstack/react-query";
import { useCallback, useEffect } from "react";
import type { NotificationChange, Session } from "./contract";
import { useServices } from "./services";

function useBellCount() {
  const { keys, guard, queryClient } = useServices();
  return useCallback(
    (unread: number, answeredAt: number) => {
      if (!guard.isActive()) return;
      const state = queryClient.getQueryState<Session>(keys.session);
      const bell = state?.data?.notifications;
      if (!state?.data || !bell || bell.unread === unread || state.dataUpdatedAt > answeredAt) return;
      queryClient.setQueryData<Session>(keys.session, { ...state.data, notifications: { ...bell, unread } });
    },
    [guard, queryClient, keys.session],
  );
}

export function useNotifications() {
  const { api, keys } = useServices();
  const setBell = useBellCount();
  const list = useQuery({
    queryKey: keys.notifications,
    queryFn: ({ signal }) => api.notifications(signal),
  });
  const unread = list.data?.unread;
  const fetchedAt = list.dataUpdatedAt;
  useEffect(() => {
    if (unread !== undefined) setBell(unread, fetchedAt);
  }, [unread, fetchedAt, setBell]);
  return list;
}

export type NotificationCommand = { kind: "read"; id: string } | { kind: "read_all"; through: string } | { kind: "clear"; through: string };

export function useNotificationCommand() {
  const { api, keys, guard, queryClient } = useServices();
  const setBell = useBellCount();
  return useMutation({
    mutationFn: (command: NotificationCommand): Promise<NotificationChange> => {
      if (command.kind === "read") return api.markNotificationRead(command.id);
      if (command.kind === "read_all") return api.markNotificationsRead(command.through);
      return api.clearNotifications(command.through);
    },
    onSuccess: (answer) => setBell(answer.unread, Date.now()),
    onSettled: () => {
      if (!guard.isActive()) return;
      void queryClient.invalidateQueries({ queryKey: keys.notifications });
      void queryClient.invalidateQueries({ queryKey: keys.session, exact: true });
    },
  });
}
