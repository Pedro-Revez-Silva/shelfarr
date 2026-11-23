import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useRouter } from "@tanstack/react-router";
import type { ManualLink, RequestCopyChoice, RequestWithdrawal } from "./api/client";
import { useServices } from "./services";

function useRequestChange<V, T>(requestId: string, send: (variables: V) => Promise<T>, onSuccess?: (answer: T) => void) {
  const { keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: send,
    onSuccess,
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

export function useWithdrawRequest(requestId: string) {
  const { api } = useServices();
  const navigate = useNavigate();
  const router = useRouter();
  const page = `/requests/${requestId}`;
  return useRequestChange(
    requestId,
    (withdrawal: RequestWithdrawal) => api.withdrawRequest(requestId, withdrawal),
    (answer) => (answer.request.status === "removed" && router.state.location.pathname === page ? void navigate({ to: "/requests", replace: true }) : undefined),
  );
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
