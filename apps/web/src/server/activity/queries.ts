import { useQuery } from "@tanstack/react-query";
import { useServices } from "../../services";
import { useIsAdministrator, useServerKeys } from "../queries";
import { activityLog } from "./api";
import type { ActivityFilters } from "./contract";

export function useActivityLog(filters: ActivityFilters) {
  const { api } = useServices();
  const root = useServerKeys().root;
  return useQuery({
    queryKey: [...root, "activity", filters.user ?? "", filters.action ?? "", filters.from ?? ""] as const,
    queryFn: ({ signal }) => activityLog(api, filters, signal),
    enabled: useIsAdministrator(),
    placeholderData: (previous) => previous,
    refetchOnWindowFocus: false,
    staleTime: 0,
  });
}
