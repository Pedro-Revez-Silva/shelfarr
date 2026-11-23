import type { ApiClient } from "../../api/client";
import { activityLogSchema, type ActivityFilters, type ActivityLog } from "./contract";

export function activityQuery(filters: ActivityFilters): string {
  const query = new URLSearchParams();
  if (filters.user) query.set("user_id", filters.user);
  if (filters.action) query.set("action_filter", filters.action);
  if (filters.from) query.set("from", filters.from);
  const text = query.toString();
  return text ? `?${text}` : "";
}

export function activityLog(api: ApiClient, filters: ActivityFilters, signal?: AbortSignal): Promise<ActivityLog> {
  return api.request({ path: `/admin/activity${activityQuery(filters)}`, schema: activityLogSchema, signal, account: (value) => value.account });
}
