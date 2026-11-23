import { useMutation, useQuery } from "@tanstack/react-query";
import { useCallback, useEffect } from "react";
import type { NotificationChange, Session } from "./contract";
import { useSession } from "./queries";
import { useServices } from "./services";

function useBellCount() {
  const { keys, guard, queryClient } = useServices();
  return useCallback(
    (unread: number) => {
      if (!guard.isActive()) return;
      const current = queryClient.getQueryData<Session>(keys.session);
      const bell = current?.notifications;
      if (!current || !bell || bell.unread === unread) return;
      queryClient.setQueryData<Session>(keys.session, { ...current, notifications: { ...bell, unread } });
    },
    [guard, queryClient, keys.session],
  );
}

export function useNotifications() {
  const { api, keys, queryClient } = useServices();
  const setBell = useBellCount();
  const list = useQuery({
    queryKey: keys.notifications,
    queryFn: ({ signal }) => api.notifications(signal),
  });
  const session = useSession();
  const bell = session.data?.notifications?.unread;
  const sessionAnsweredAt = session.dataUpdatedAt;
  const unread = list.data?.unread;
  const listAnsweredAt = list.dataUpdatedAt;
  useEffect(() => {
    if (unread !== undefined) setBell(unread);
  }, [unread, listAnsweredAt, setBell]);
  useEffect(() => {
    if (unread === undefined || bell === undefined || bell === unread || sessionAnsweredAt <= listAnsweredAt) return;
    void queryClient.invalidateQueries({ queryKey: keys.notifications });
  }, [bell, sessionAnsweredAt]);
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
    onSuccess: (answer) => setBell(answer.unread),
    onSettled: () => {
      if (!guard.isActive()) return;
      void queryClient.invalidateQueries({ queryKey: keys.notifications });
      void queryClient.invalidateQueries({ queryKey: keys.session, exact: true });
    },
  });
}
