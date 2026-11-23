import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { failureKind, isApiError } from "../../api/errors";
import { describeWriteFailure } from "../../components/accountFields";
import { useServices } from "../../services";
import * as koboApi from "./api";
import type { KoboDelivery, KoboReader, KoboReaders, KoboSettings } from "./contract";

export function useKoboKeys() {
  const { keys } = useServices();
  const root = [...keys.root, "kobo"] as const;
  return { root, list: [...root, "list"] as const, reader: (id: string) => [...root, "reader", id] as const, book: (id: string) => [...root, "book", id] as const };
}

export function isMissingReader(error: unknown): boolean {
  return isApiError(error) && error.code === "reader_not_found";
}

export function koboFailure(error: unknown, uncertain: string): string {
  if (!isApiError(error)) return uncertain;
  if (error.code === "kobo_send_refused") return error.message;
  if (error.code === "reader_not_found") return "That Kobo reader is no longer connected to your account. Nothing was sent.";
  if (error.code === "book_not_found") return "This book is no longer in the library. Nothing was sent.";
  return describeWriteFailure(error, uncertain);
}

function keepTrying(count: number, error: unknown): boolean {
  return failureKind(error) !== "not_found" && count < 2;
}

export function useKoboReaders() {
  const { api, mode } = useServices();
  return useQuery({ queryKey: useKoboKeys().list, queryFn: ({ signal }) => koboApi.readers(api, signal), enabled: mode === "rails", refetchOnWindowFocus: false, staleTime: 0, retry: keepTrying });
}

export function useKoboReader(id: string) {
  const { api, mode } = useServices();
  return useQuery({ queryKey: useKoboKeys().reader(id), queryFn: ({ signal }) => koboApi.reader(api, id, signal), enabled: mode === "rails", refetchOnWindowFocus: false, staleTime: 0, retry: keepTrying });
}

export function useBookKobo(publicationId: string, enabled: boolean) {
  const { api, mode } = useServices();
  return useQuery({ queryKey: useKoboKeys().book(publicationId), queryFn: ({ signal }) => koboApi.bookReaders(api, publicationId, signal), enabled: enabled && mode === "rails", staleTime: 0, retry: keepTrying });
}

export type KoboPublish = { reader: (reader: KoboReader) => void; forget: (id: string) => void; refresh: () => void };

export function useKoboPublish(): KoboPublish & { active: () => boolean; lost: (error: unknown) => void } {
  const { guard, revalidate } = useServices();
  const keys = useKoboKeys();
  const client = useQueryClient();
  const refresh = () => {
    void client.invalidateQueries({ queryKey: keys.list });
  };
  return {
    active: () => guard.isActive(),
    reader: (reader) => {
      if (!guard.isActive()) return;
      client.setQueryData(keys.reader(reader.id), reader);
      client.setQueryData<KoboReaders>(keys.list, (current) =>
        current ? { ...current, readers: current.readers.map((row) => (row.id === reader.id ? { ...row, ...pickRow(reader) } : row)) } : current,
      );
      refresh();
    },
    forget: (id) => {
      if (!guard.isActive()) return;
      client.removeQueries({ queryKey: keys.reader(id), exact: true });
      client.setQueryData<KoboReaders>(keys.list, (current) => (current ? { ...current, readers: current.readers.filter((row) => row.id !== id) } : current));
      void client.invalidateQueries({ queryKey: [...keys.root, "book"] });
      refresh();
    },
    refresh,
    lost: (error) => {
      if (!guard.isActive()) return;
      if (failureKind(error) === "not_found" && !isMissingReader(error)) revalidate();
    },
  };
}

function pickRow(reader: KoboReader) {
  const { store_status: _status, placeholder_sign_in: _placeholder, store_endpoint: _endpoint, deliveries: _deliveries, ...row } = reader;
  return row;
}

export function useKoboWrite<Input, Answer>(write: (input: Input) => Promise<Answer>, settle: (answer: Answer, publish: KoboPublish) => void) {
  const publish = useKoboPublish();
  return useMutation({
    mutationFn: write,
    onSuccess: (answer) => {
      if (publish.active()) settle(answer, publish);
    },
    onError: publish.lost,
  });
}

export function useChoosePlace(id: string) {
  const { api } = useServices();
  return useKoboWrite(({ delivery, place }: { delivery: Pick<KoboDelivery, "entitlement_id" | "choice">; place: "kobo" | "shelfarr" }) => koboApi.choosePlace(api, id, delivery, place), (answer, publish) => publish.reader(answer.reader));
}

export function useSaveSettings(id: string) {
  const { api } = useServices();
  return useKoboWrite(
    ({ values, version }: { values: KoboSettings; version: string }) => koboApi.saveSettings(api, id, values, version),
    (answer, publish) => {
      if (answer.kind !== "rejected") publish.reader(answer.reader);
    },
  );
}

export function useRevoke(id: string) {
  const { api } = useServices();
  return useKoboWrite(
    (version: string) => koboApi.revoke(api, id, version),
    (answer, publish) => {
      if (answer.kind === "revoked") publish.forget(id);
      else publish.reader(answer.reader);
    },
  );
}

export function useSendBook(publicationId: string) {
  const { api } = useServices();
  const keys = useKoboKeys();
  const client = useQueryClient();
  return useKoboWrite(
    (readerId: string) => koboApi.sendBook(api, readerId, publicationId),
    (answer) => {
      void client.invalidateQueries({ queryKey: keys.reader(answer.reader.id) });
    },
  );
}
