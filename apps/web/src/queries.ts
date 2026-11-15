import {
  queryOptions,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import type { LibraryFilters, LibraryPage, PublicationDetail, ReadingStatus } from "./contract";
import { useServices } from "./services";

export function useSession() {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.session,
    queryFn: ({ signal }) => api.session(signal),
    staleTime: 15_000,
    refetchOnWindowFocus: "always",
  });
}

export function useContinueReading(filters: LibraryFilters, enabled: boolean) {
  const { api, keys } = useServices();
  return useQuery({
    queryKey: keys.continueReading(filters),
    queryFn: ({ signal }) => api.continueReading(filters, signal),
    enabled,
  });
}

export function useLibrary(filters: LibraryFilters) {
  const { api, keys } = useServices();
  return useInfiniteQuery({
    queryKey: keys.library(filters),
    queryFn: ({ pageParam, signal }) => api.library(filters, pageParam, signal),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last: LibraryPage) => last.next_cursor ?? undefined,
  });
}

export function usePublication(id: string) {
  const { api, keys } = useServices();
  return useQuery(
    queryOptions({
      queryKey: keys.publication(id),
      queryFn: ({ signal }) => api.publication(id, signal),
    }),
  );
}

export function useReadingStatus(id: string) {
  const { api, keys, guard } = useServices();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (status: ReadingStatus) => api.setReadingStatus(id, status),
    onSuccess: (publication: PublicationDetail) => {
      if (!guard.isActive()) return;
      client.setQueryData(keys.publication(id), publication);
      void client.invalidateQueries({ queryKey: keys.libraryAll });
      void client.invalidateQueries({ queryKey: keys.continueAll });
    },
  });
}

export function flattenLibrary(data: InfiniteData<LibraryPage> | undefined) {
  if (!data) return [];
  const seen = new Set<string>();
  return data.pages.flatMap((page) => page.items).filter((item) => (seen.has(item.id) ? false : (seen.add(item.id), true)));
}
