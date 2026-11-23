import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ApiClient } from "../api/client";
import { failureKind } from "../api/errors";
import { useServices } from "../services";
import { uploadCreatedSchema, uploadMatchesSchema, uploadOutcomeSchema, uploadRequestSchema, uploadsSchema, type UploadCreated, type UploadMatches, type UploadOutcome, type UploadRequest, type Uploads } from "./contract";

const account = (value: { account: string }) => value.account;
const ACTIVE_REFRESH_MS = 5000;

export type UploadSubmission = { files: File[]; folder: boolean; requestId: string | null };

export type UploadCommand = { kind: "retry"; id: string } | { kind: "remove"; id: string } | { kind: "match_book"; id: string; bookId: string } | { kind: "match_new"; id: string; title: string; author: string };

export function uploads(api: ApiClient, page: number, signal?: AbortSignal): Promise<Uploads> {
  return api.request({ path: page > 1 ? `/uploads?page=${page}` : "/uploads", schema: uploadsSchema, signal, account });
}

export async function uploadRequest(api: ApiClient, requestId: string, signal?: AbortSignal): Promise<UploadRequest> {
  const answer = await api.request({ path: `/uploads/requests/${encodeURIComponent(requestId)}`, schema: uploadRequestSchema, signal, account });
  return answer.request;
}

export function uploadForm(submission: UploadSubmission): FormData {
  const form = new FormData();
  if (submission.requestId) {
    form.set("request_id", submission.requestId);
    const [file] = submission.files;
    if (file) form.set("file", file, file.name);
    return form;
  }
  form.set("upload_mode", submission.folder ? "folder" : "files");
  for (const file of submission.files) form.append("files[]", file, file.name);
  return form;
}

export function sendUpload(api: ApiClient, submission: UploadSubmission, signal?: AbortSignal): Promise<UploadCreated> {
  return api.request({ path: "/uploads", method: "POST", form: uploadForm(submission), schema: uploadCreatedSchema, signal, account });
}

export async function runUploadCommand(api: ApiClient, command: UploadCommand, signal?: AbortSignal): Promise<UploadOutcome> {
  const base = `/admin/uploads/${encodeURIComponent(command.id)}`;
  const options = (() => {
    switch (command.kind) {
      case "retry":
        return { path: `${base}/retry`, method: "POST" as const, body: {} };
      case "remove":
        return { path: base, method: "DELETE" as const, body: {} };
      case "match_book":
        return { path: `${base}/match`, method: "POST" as const, body: { book_id: command.bookId } };
      case "match_new":
        return { path: `${base}/match`, method: "POST" as const, body: { manual_book: { title: command.title, author: command.author } } };
    }
  })();
  const answer = await api.request({ ...options, schema: uploadOutcomeSchema, signal, account });
  return answer.outcome;
}

export function uploadMatches(api: ApiClient, id: string, query: string | null, page: number, signal?: AbortSignal): Promise<UploadMatches> {
  const search = new URLSearchParams();
  if (query !== null) search.set("q", query);
  if (page > 1) search.set("page", String(page));
  const suffix = search.toString();
  return api.request({ path: `/admin/uploads/${encodeURIComponent(id)}/matches${suffix ? `?${suffix}` : ""}`, schema: uploadMatchesSchema, signal, account });
}

export function useUploadKeys() {
  const { keys } = useServices();
  const root = [...keys.root, "uploads"] as const;
  return {
    lists: [...root, "list"] as const,
    list: (page: number) => [...root, "list", page] as const,
    request: (id: string) => [...root, "request", id] as const,
    allMatches: [...root, "matches"] as const,
    matches: (id: string, query: string | null, page: number) => [...root, "matches", id, query, page] as const,
  };
}

function busy(data: Uploads | undefined): boolean {
  return data?.items.some((upload) => upload.status === "pending" || upload.status === "processing") ?? false;
}

export function useUploads(page: number) {
  const { api } = useServices();
  const keys = useUploadKeys();
  return useQuery({
    queryKey: keys.list(page),
    queryFn: ({ signal }) => uploads(api, page, signal),
    placeholderData: keepPreviousData,
    refetchInterval: (query) => (busy(query.state.data) ? ACTIVE_REFRESH_MS : false),
    staleTime: 0,
  });
}

export function useUploadRequest(requestId: string | undefined) {
  const { api } = useServices();
  const keys = useUploadKeys();
  return useQuery({
    queryKey: keys.request(requestId ?? ""),
    queryFn: ({ signal }) => uploadRequest(api, requestId ?? "", signal),
    enabled: requestId !== undefined,
    retry: false,
    staleTime: 0,
    refetchOnWindowFocus: false,
  });
}

export function useUploadMatches(id: string, query: string | null, page: number) {
  const { api } = useServices();
  const keys = useUploadKeys();
  return useQuery({
    queryKey: keys.matches(id, query, page),
    queryFn: ({ signal }) => uploadMatches(api, id, query, page, signal),
    placeholderData: keepPreviousData,
    retry: false,
    staleTime: 0,
  });
}

function useAfterUploadChange() {
  const { guard, keys } = useServices();
  const uploadKeys = useUploadKeys();
  const client = useQueryClient();
  return (error: unknown | null, requestId: string | null) => {
    if (!guard.isActive()) return;
    void client.invalidateQueries({ queryKey: uploadKeys.lists });
    void client.invalidateQueries({ queryKey: uploadKeys.allMatches });
    void client.invalidateQueries({ queryKey: keys.libraryAll });
    if (requestId) {
      void client.invalidateQueries({ queryKey: keys.request(requestId) });
      void client.invalidateQueries({ queryKey: keys.requestsAll });
    }
    if (error !== null && failureKind(error) === "not_found") void client.invalidateQueries({ queryKey: keys.session });
  };
}

export function useSendUpload() {
  const { api } = useServices();
  const after = useAfterUploadChange();
  return useMutation({
    mutationFn: (submission: UploadSubmission) => sendUpload(api, submission),
    onSettled: (_data, error, submission) => after(error, submission.requestId),
  });
}

export function useUploadCommand() {
  const { api } = useServices();
  const after = useAfterUploadChange();
  return useMutation({
    mutationFn: (command: UploadCommand) => runUploadCommand(api, command),
    onSettled: (_data, error) => after(error, null),
  });
}
