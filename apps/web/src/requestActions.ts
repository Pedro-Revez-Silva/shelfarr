import { useMutation, useQueryClient } from "@tanstack/react-query";
import type { ManualLink, RequestCopyChoice } from "./api/client";
import { useServices } from "./services";

function useRequestChange<V, T>(requestId: string, send: (variables: V) => Promise<T>) {
  const { keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: send,
    onSettled: () => {
      if (!guard.isActive()) return;
      for (const queryKey of [keys.request(requestId), keys.requestsAll, keys.libraryAll, keys.continueAll, keys.catalogueAll, [...keys.root, "book"]]) {
        void client.invalidateQueries({ queryKey });
      }
    },
  });
}

export function useCancelTrackedRequest(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, () => api.cancelRequest(requestId));
}

export function useRetryRequest(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, () => api.retryRequest(requestId));
}

export function useRemoveRequest(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, () => api.removeRequest(requestId));
}

export function useSearchRequestAgain(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, () => api.searchAgain(requestId));
}

export function useChooseRequestCopy(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, (choice: RequestCopyChoice) => api.chooseRequestCopy(requestId, choice));
}

export function useManualLink(requestId: string) {
  const { api } = useServices();
  return useRequestChange(requestId, (link: ManualLink) => api.addManualLink(requestId, link));
}
