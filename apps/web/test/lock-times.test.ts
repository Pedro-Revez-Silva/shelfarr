import { describe, expect, test } from "bun:test";
import { AccountGuard } from "../src/api/account-guard";
import { ApiClient } from "../src/api/client";
import { AuthClient, CsrfSession } from "../src/go/auth";
import { fetchBook } from "../src/reader/media";
import { guardedFetch } from "../src/reader/pages";
import { createServices } from "../src/services";
import { waitFor } from "@testing-library/react";
import { boot } from "./helpers";
import { signedOut } from "./go-helpers";

const ANSWER_DELAY_MS = 30;
const PLACE = { asset_id: "a", locator: { href: "one.xhtml" }, observed_at: "2026-11-20T11:00:00.000Z", expected_version: 0, client_mutation_id: "m" };

function slowAnswer(status: number, body: unknown) {
  const sent: number[] = [];
  const fetcher = (async () => {
    sent.push(Date.now());
    await new Promise((resolve) => setTimeout(resolve, ANSWER_DELAY_MS));
    return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { fetcher, sent };
}

async function settled(promise: Promise<unknown>): Promise<void> {
  await promise.catch(() => undefined);
}

function lockedWhenSent(guard: AccountGuard, sent: number[]): void {
  expect(guard.isActive()).toBe(false);
  expect(sent).toHaveLength(1);
  expect(guard.lockAskedAt).not.toBeNull();
  expect(guard.lockAskedAt!).toBeLessThanOrEqual(sent[0]!);
}

describe("a lock carries the moment its refused request was sent", () => {
  test("an API request answered signed out later", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(401, { error: "signed_out" });
    const client = new ApiClient({ boot, guard, csrfToken: () => "token", fetcher });
    await settled(client.saveProgress("7", PLACE));
    lockedWhenSent(guard, sent);
  });

  test("an API answer for another account", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(200, { account: "4", progress: null });
    const client = new ApiClient({ boot, guard, csrfToken: () => "token", fetcher });
    await settled(client.saveProgress("7", PLACE));
    lockedWhenSent(guard, sent);
  });

  test("a token refresh answered signed out later", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(200, signedOut());
    const csrf = new CsrfSession(new AuthClient("/preview/api/v1", fetcher), guard, "token", 0);
    await settled(csrf.refresh());
    lockedWhenSent(guard, sent);
  });

  test("a book download answered signed out later", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(401, { error: "signed_out" });
    const network = globalThis.fetch;
    globalThis.fetch = fetcher;
    try {
      await settled(fetchBook(new URL("/preview/api/v1/accounts/5/library/7/assets/x", window.location.href).href, guard, new AbortController().signal));
    } finally {
      globalThis.fetch = network;
    }
    lockedWhenSent(guard, sent);
  });

  test("a session check answered signed out later", async () => {
    const { fetcher, sent } = slowAnswer(401, { error: "signed_out" });
    const services = createServices({ boot, csrfToken: () => null, fetcher });
    services.revalidate();
    await waitFor(() => expect(services.guard.isActive()).toBe(false));
    lockedWhenSent(services.guard, sent);
  });

  test("a page read answered signed out later", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(401, { error: "signed_out" });
    await settled(guardedFetch(guard, fetcher as unknown as (input: string, init: RequestInit) => Promise<Response>)("/preview/api/v1/library/7/assets/x/reading_order", {}));
    lockedWhenSent(guard, sent);
  });
});

describe("refusals after a lock", () => {
  test("a refusal answered after a lock without a send time still reaches its listeners with its own send time", () => {
    const guard = new AccountGuard("5");
    const refusals: number[] = [];
    guard.subscribeRefusals((askedAt) => refusals.push(askedAt));
    guard.lock("access_changed");
    expect(refusals).toEqual([]);
    guard.lock("signed_out", 1234);
    expect(refusals).toEqual([1234]);
    expect(guard.getState()).toEqual({ status: "access_changed" });
    expect(guard.lockAskedAt).toBe(1234);
  });
});

describe("page answers that are not refusals", () => {
  test("a page answer whose body read is cancelled is an abort, not an account change", async () => {
    const guard = new AccountGuard("5");
    const refusals: number[] = [];
    guard.subscribeRefusals((askedAt) => refusals.push(askedAt));
    const controller = new AbortController();
    const fetcher = async (_input: string, init: RequestInit) =>
      new Response(
        new ReadableStream({
          start(stream) {
            init.signal?.addEventListener("abort", () => stream.error(new DOMException("Aborted", "AbortError")));
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    const read = guardedFetch(guard, fetcher)("/preview/api/v1/library/7/assets/x/reading_order", { signal: controller.signal });
    setTimeout(() => controller.abort(), 10);
    await expect(read).rejects.toMatchObject({ name: "AbortError" });
    expect(guard.isActive()).toBe(true);
    expect(refusals).toEqual([]);
  });

  test("a page answer without an account locks the page but is not dated as a refusal", async () => {
    const guard = new AccountGuard("5");
    const refusals: number[] = [];
    guard.subscribeRefusals((askedAt) => refusals.push(askedAt));
    const fetcher = async () => new Response("not json", { status: 200 });
    await settled(guardedFetch(guard, fetcher)("/preview/api/v1/library/7/assets/x/reading_order", {}));
    expect(guard.getState()).toEqual({ status: "account_changed" });
    expect(refusals).toEqual([]);
  });

  test("a page answer naming another account is a refusal dated when it was sent", async () => {
    const guard = new AccountGuard("5");
    const { fetcher, sent } = slowAnswer(200, { account: "4" });
    await settled(guardedFetch(guard, fetcher as unknown as (input: string, init: RequestInit) => Promise<Response>)("/preview/api/v1/library/7/assets/x/reading_order", {}));
    lockedWhenSent(guard, sent);
  });
});
