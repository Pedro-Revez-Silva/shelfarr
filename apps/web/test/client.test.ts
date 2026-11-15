import { describe, expect, test } from "bun:test";
import { AccountGuard } from "../src/api/account-guard";
import { ApiClient, ACCOUNT_HEADER } from "../src/api/client";
import { isApiError, type FailureKind } from "../src/api/errors";
import { createServices } from "../src/services";
import { ACCOUNT, MOUNT, boot, deferred, detail, FakeServer, page, session, summary } from "./helpers";

function clientFor(server: FakeServer, csrf: string | null = "csrf-1") {
  const guard = new AccountGuard(ACCOUNT);
  return { guard, client: new ApiClient({ boot, guard, csrfToken: () => csrf, fetcher: server.fetcher }) };
}

async function failure(promise: Promise<unknown>) {
  try {
    await promise;
  } catch (error) {
    if (isApiError(error)) return error;
    throw error;
  }
  throw new Error("expected a failure");
}

describe("the API client", () => {
  test("every request names the account and stays under the mounted API path", async () => {
    const server = new FakeServer().on("GET", /.*/, () => ({ body: page([summary()]) }));
    const { client } = clientFor(server);
    await client.library({ q: "dune & co", type: "audiobook", status: "in_progress", sort: "title" }, "cursor 1");
    const [request] = server.requests;
    expect(request?.path).toBe(`${MOUNT}/api/v1/library?q=dune+%26+co&type=audiobook&status=in_progress&sort=title&cursor=cursor+1`);
    expect(request?.headers[ACCOUNT_HEADER.toLowerCase()]).toBe(ACCOUNT);
    expect(request?.headers.accept).toBe("application/json");
    expect(request?.headers["x-csrf-token"]).toBeUndefined();
  });

  test("a status change sends JSON with the CSRF token and the account", async () => {
    const server = new FakeServer().on("PUT", /reading_status$/, () => ({ body: { account: ACCOUNT, publication: detail({ reading_status: "finished" }) } }));
    const { client } = clientFor(server, "token-9");
    const result = await client.setReadingStatus("7", "finished");
    const [request] = server.requests;
    expect(request).toMatchObject({ method: "PUT", path: `${MOUNT}/api/v1/library/7/reading_status`, body: { status: "finished" } });
    expect(request?.headers["x-csrf-token"]).toBe("token-9");
    expect(request?.headers["content-type"]).toBe("application/json");
    expect(request?.headers[ACCOUNT_HEADER.toLowerCase()]).toBe(ACCOUNT);
    expect(result.reading_status).toBe("finished");
  });

  test("a signed-out answer locks the client and later calls never reach the network", async () => {
    const server = new FakeServer().on("GET", /session$/, () => ({ status: 401, body: { error: "signed_out" } }));
    const { client, guard } = clientFor(server);
    expect((await failure(client.session())).kind).toBe("signed_out");
    expect(guard.getState().status).toBe("signed_out");
    const before = server.requests.length;
    expect((await failure(client.library({}, undefined))).kind).toBe("signed_out");
    expect(server.requests.length).toBe(before);
  });

  test("an account mismatch from the server locks the client", async () => {
    const server = new FakeServer().on("GET", /library/, () => ({ status: 401, body: { error: "account_changed" } }));
    const { client, guard } = clientFor(server);
    expect((await failure(client.library({}, undefined))).kind).toBe("account_changed");
    expect(guard.getState().status).toBe("account_changed");
  });

  test("a body for another account is refused and locks the client", async () => {
    const server = new FakeServer().on("GET", /library/, () => ({ body: { ...page([summary()]), account: "99" } }));
    const { client, guard } = clientFor(server);
    expect((await failure(client.library({}, undefined))).kind).toBe("account_changed");
    expect(guard.getState().status).toBe("account_changed");
  });

  test("a session that names another account is refused", async () => {
    const server = new FakeServer().on("GET", /session$/, () => ({ body: session({ account: { id: "99", name: "Someone Else" } }) }));
    const { client, guard } = clientFor(server);
    expect((await failure(client.session())).kind).toBe("account_changed");
    expect(guard.isActive()).toBe(false);
  });

  test("a response that arrives after the account changed is never delivered", async () => {
    const gate = deferred<void>();
    const server = new FakeServer().on("GET", /library/, async () => {
      await gate.promise;
      return { body: page([summary({ title: "Previous account's book" })]) };
    });
    const { client, guard } = clientFor(server);
    const pending = failure(client.library({}, undefined));
    guard.lock("account_changed");
    gate.resolve();
    expect((await pending).kind).toBe("account_changed");
  });

  test("failures are classified", async () => {
    const cases: [number, unknown, FailureKind][] = [
      [404, { error: "not_found" }, "not_found"],
      [400, { error: "invalid_request", message: "Unknown library sort" }, "invalid"],
      [422, { error: "invalid_csrf" }, "csrf"],
      [422, { error: "invalid_reading_status", message: "Choose unread" }, "invalid"],
      [500, { error: "internal" }, "server"],
      [502, null, "server"],
      [200, "<html>sign in</html>", "contract"],
    ];
    for (const [status, body, kind] of cases) {
      const server = new FakeServer().on("GET", /session$/, () => ({ status, body }));
      const { client, guard } = clientFor(server);
      expect((await failure(client.session())).kind).toBe(kind);
      expect(guard.isActive()).toBe(true);
    }
  });

  test("a body that does not match the contract is a contract failure, not a cast", async () => {
    const server = new FakeServer().on("GET", /library/, () => ({ body: { account: ACCOUNT, items: [{ id: 7 }], next_cursor: null } }));
    const { client } = clientFor(server);
    expect((await failure(client.library({}, undefined))).kind).toBe("contract");
  });

  test("a network failure is recoverable and does not lock", async () => {
    const guard = new AccountGuard(ACCOUNT);
    const client = new ApiClient({ boot, guard, csrfToken: () => null, fetcher: (async () => { throw new TypeError("Failed to fetch"); }) as unknown as typeof fetch });
    expect((await failure(client.session())).kind).toBe("network");
    expect(guard.isActive()).toBe(true);
  });

  test("an aborted request rethrows the abort", async () => {
    const controller = new AbortController();
    const server = new FakeServer().on("GET", /session$/, () => {
      controller.abort();
      return { body: session() };
    });
    const { client } = clientFor(server);
    await expect(client.session(controller.signal)).rejects.toMatchObject({ name: "AbortError" });
  });

  test("locking cancels in-flight queries and empties the cache", async () => {
    const gate = deferred<void>();
    const server = new FakeServer().on("GET", /session$/, async (request) => {
      await gate.promise;
      return request.signal?.aborted ? { status: 499 } : { body: session() };
    });
    const services = createServices({ boot, csrfToken: () => null, fetcher: server.fetcher });
    services.queryClient.setQueryData(services.keys.publication("7"), detail());
    const pending = services.queryClient.fetchQuery({ queryKey: services.keys.session, queryFn: ({ signal }) => services.api.session(signal) }).catch((error: unknown) => error);
    await Promise.resolve();
    services.guard.lock("signed_out");
    gate.resolve();
    expect(await pending).toBeInstanceOf(Error);
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
  });

  test("query keys carry the account", () => {
    const services = createServices({ boot, csrfToken: () => null });
    for (const key of [services.keys.session, services.keys.library({ q: "a" }), services.keys.continueReading({}), services.keys.publication("7")]) {
      expect(key.slice(0, 2)).toEqual(["account", ACCOUNT]);
    }
    const other = createServices({ boot: { ...boot, account: "13" }, csrfToken: () => null });
    expect(other.keys.library({})).not.toEqual(services.keys.library({}));
  });
});
