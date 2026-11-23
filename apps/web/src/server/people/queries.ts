import { useIsMutating, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, useEffect } from "react";
import { failureKind, isApiError } from "../../api/errors";
import { useServices } from "../../services";
import { useIsAdministrator, useServerKeys } from "../queries";
import * as peopleApi from "./api";
import type { People, PersonEnvelope } from "./contract";

const PEOPLE_WRITE = ["people-write"] as const;

export function usePeopleKeys() {
  const root = [...useServerKeys().root, "people"] as const;
  return { root, list: [...root, "list"] as const, person: (id: string) => [...root, "person", id] as const };
}

export function isRemovedPerson(error: unknown): boolean {
  return isApiError(error) && error.code === "user_not_found";
}

export function usePeople() {
  const { api } = useServices();
  const keys = usePeopleKeys();
  return useQuery({ queryKey: keys.list, queryFn: ({ signal }) => peopleApi.people(api, signal), enabled: useIsAdministrator(), refetchOnWindowFocus: false, staleTime: 0 });
}

export function usePerson(id: string) {
  const { api } = useServices();
  const keys = usePeopleKeys();
  return useQuery({
    queryKey: keys.person(id),
    queryFn: ({ signal }) => peopleApi.person(api, id, signal),
    enabled: useIsAdministrator(),
    refetchOnWindowFocus: false,
    staleTime: 0,
    retry: (count, error) => !isRemovedPerson(error) && failureKind(error) !== "not_found" && count < 2,
  });
}

function usePeopleWrite<Input, Answer extends { kind: string }>(write: (input: Input) => Promise<Answer>, settle: (answer: Answer, publish: Publish) => void) {
  const { guard, revalidate } = useServices();
  const keys = usePeopleKeys();
  const serverKeys = useServerKeys();
  const client = useQueryClient();
  const publish: Publish = {
    person: (envelope) => client.setQueryData(keys.person(envelope.user.id), envelope),
    forget: (id) => {
      client.removeQueries({ queryKey: keys.person(id), exact: true });
      client.setQueryData<People>(keys.list, (current) => (current ? { ...current, users: current.users.filter((entry) => entry.id !== id) } : current));
    },
    roleChanged: revalidate,
  };
  return useMutation({
    mutationKey: PEOPLE_WRITE,
    mutationFn: write,
    onSuccess: async (answer) => {
      if (!guard.isActive()) return;
      await client.cancelQueries({ queryKey: keys.root });
      settle(answer, publish);
      void client.invalidateQueries({ queryKey: keys.list });
      void client.invalidateQueries({ queryKey: serverKeys.overview });
    },
    onError: (error) => {
      if (!guard.isActive()) return;
      if (failureKind(error) === "not_found" && !isRemovedPerson(error)) revalidate();
      void client.invalidateQueries({ queryKey: keys.root });
    },
  });
}

type Publish = { person: (envelope: PersonEnvelope) => void; forget: (id: string) => void; roleChanged: () => void };

function publishPerson(answer: peopleApi.PersonAnswer, publish: Publish) {
  if (answer.kind === "saved" || answer.kind === "changed") publish.person(answer.person);
}

export function useAddPerson() {
  const { api } = useServices();
  return usePeopleWrite((values: peopleApi.NewPerson) => peopleApi.addPerson(api, values), publishPerson);
}

export function useSaveProfile(id: string, self: boolean) {
  const { api } = useServices();
  return usePeopleWrite(
    ({ values, version, administrators }: { values: peopleApi.ProfileValues; version: string; administrators: number | null }) => peopleApi.saveProfile(api, id, values, version, administrators),
    (answer, publish) => {
      publishPerson(answer, publish);
      if (self && answer.kind === "saved" && answer.person.user.role !== "administrator") publish.roleChanged();
    },
  );
}

export function useSetPassword(id: string) {
  const { api } = useServices();
  return usePeopleWrite((values: peopleApi.PasswordValues) => peopleApi.setPassword(api, id, values), publishPerson);
}

export function useRemovePerson(id: string) {
  const { api } = useServices();
  return usePeopleWrite(
    (version: string) => peopleApi.removePerson(api, id, version),
    (answer, publish) => {
      if (answer.kind === "removed") publish.forget(answer.id);
      else if (answer.kind === "changed") publish.person(answer.person);
    },
  );
}

export function usePeopleWriting(): boolean {
  return useIsMutating({ mutationKey: PEOPLE_WRITE }) > 0;
}

const arrivals = new Map<string, string>();

export function announceArrival(id: string, text: string) {
  arrivals.set(id, text);
}

export function useArrival(id: string): string | null {
  const [text] = useState(() => arrivals.get(id) ?? null);
  useEffect(() => {
    arrivals.delete(id);
  }, [id]);
  return text;
}
