import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { metadataSettingsSchema, type MetadataSettings } from "../src/contract";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { ACCOUNT, FakeServer, page, session, summary, type Handler, type RecordedRequest } from "./helpers";
import { error, renderGo, signedOut } from "./go-helpers";

const SETTINGS = /\/api\/v1\/admin\/settings\/metadata$/;
const SESSION = /\/api\/v1\/session$/;
const DISCOVER = /\/api\/v1\/discover(\?|$)/;
const OVERVIEW = /\/api\/v1\/admin\/overview$/;

type Reply = Awaited<ReturnType<Handler>>;

function settings(overrides: Partial<MetadataSettings> = {}, values: Partial<MetadataSettings["open_library"]> = {}, discover: Partial<MetadataSettings["discover"]> = {}): MetadataSettings {
  return {
    account: ACCOUNT,
    revision: "0123456789abcdef0123456789abcdef",
    open_library: { enabled: true, search_limit: 20, ...values },
    defaults: { enabled: true, search_limit: 20 },
    search_limit_range: { min: 1, max: 1000 },
    discover: { search: "available", result_limit: 20, max_results: 20, ...discover },
    ...overrides,
  };
}

function settingsServer(options: { admin?: () => boolean; read?: () => Reply; save?: (request: RecordedRequest) => Reply | Promise<Reply> } = {}): FakeServer {
  const admin = options.admin ?? (() => true);
  return new FakeServer()
    .on("GET", SESSION, () => ({ body: session(admin() ? { admin: { url: "/admin" } } : {}) }))
    .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", OVERVIEW, () => ({
      body: {
        account: ACCOUNT,
        counts: { users: 1, books: 0, active_requests: 0, attention_requests: 0 },
        services: ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"].map((service) => ({ service, status: null, checked_at: null })),
      },
    }))
    .on("GET", DISCOVER, () => ({ body: { account: ACCOUNT, provider: { name: "Open Library", url: "https://openlibrary.org" }, search: "provider_disabled", query: null, items: [] } }))
    .on("GET", SETTINGS, options.read ?? (() => ({ body: settings() })))
    .on("PUT", SETTINGS, options.save ?? ((request) => ({ body: saved(request) })));
}

function saved(request: RecordedRequest): MetadataSettings {
  const change = (request.body as { open_library: { enabled?: boolean; search_limit?: number } }).open_library;
  const enabled = change.enabled ?? true;
  const limit = change.search_limit ?? 20;
  return settings({ revision: "fedcba9876543210fedcba9876543210" }, { enabled, search_limit: limit }, enabled ? { result_limit: Math.min(limit, 20) } : { search: "provider_disabled", result_limit: null });
}

function renderSettings(server: FakeServer, url = "/preview/admin/settings") {
  resetFirstPage();
  const services = createServices({
    boot: { version: 1, account: ACCOUNT, mount: "/preview", api: "/preview/api/v1", classic_library: null, runtime: "go" },
    csrfToken: () => "session-token",
    fetcher: server.fetcher,
  });
  const history = createMemoryHistory({ initialEntries: [url] });
  const router = createAppRouter({ basepath: "/preview", history });
  const view = render(<App services={services} router={router} />);
  return { services, history, view };
}

function controls() {
  return { enabled: screen.getByRole("checkbox", { name: "Use Open Library" }) as HTMLInputElement, limit: screen.getByRole("textbox", { name: "Results per search" }) as HTMLInputElement };
}

function saves(server: FakeServer) {
  return server.called("PUT", SETTINGS);
}

async function opened(server: FakeServer, url?: string) {
  const rendered = renderSettings(server, url);
  await screen.findByRole("heading", { name: "Metadata", level: 2 });
  return rendered;
}

describe("the metadata settings contract", () => {
  test("accepts saved, default and unreadable values and refuses another shape", () => {
    expect(metadataSettingsSchema.safeParse(settings()).success).toBe(true);
    expect(metadataSettingsSchema.safeParse(settings({}, { enabled: null, search_limit: null }, { search: "settings_unreadable", result_limit: null })).success).toBe(true);
    expect(metadataSettingsSchema.safeParse(settings({}, { search_limit: -3 }, { result_limit: 0 })).success).toBe(true);
    expect(metadataSettingsSchema.safeParse(settings({ revision: "abc" })).success).toBe(false);
    expect(metadataSettingsSchema.safeParse(settings({}, {}, { search: "searching" as MetadataSettings["discover"]["search"] })).success).toBe(false);
    expect(metadataSettingsSchema.safeParse(settings({}, { search_limit: 1.5 })).success).toBe(false);
  });
});

describe("the server settings page", () => {
  test("an admin reaches it from the overview, sees the saved values and what Discover does, and opening it writes nothing", async () => {
    const server = settingsServer({ read: () => ({ body: settings({}, { search_limit: 50 }) }) });
    const { history } = renderSettings(server, "/preview/admin");
    await userEvent.click(await screen.findByRole("link", { name: "Server settings" }));
    await waitFor(() => expect(history.location.pathname).toBe("/preview/admin/settings"));
    expect(await screen.findByRole("heading", { name: "Metadata", level: 2 })).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Server settings", level: 1 })).toBeTruthy();
    expect(document.title).toBe("Server settings · Shelfarr");
    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(within(nav).getByRole("link", { name: "Admin" }).getAttribute("aria-current")).toBe("page");
    expect(within(nav).getByRole("link", { name: "Account" }).getAttribute("aria-current")).toBeNull();
    expect(screen.getByRole("link", { name: "Server overview" }).getAttribute("aria-current")).toBeNull();
    expect(within(document.querySelector(".settings .lede") as HTMLElement).getByRole("link", { name: "Account" }).getAttribute("href")).toBe("/preview/account");
    const { enabled, limit } = controls();
    expect(enabled.checked).toBe(true);
    expect(limit.value).toBe("50");
    expect([limit.type, limit.inputMode]).toEqual(["text", "numeric"]);
    expect(document.getElementById(enabled.getAttribute("aria-describedby")!)!.textContent).toBe("Searches openlibrary.org for book details. Default: on.");
    expect(document.getElementById(limit.getAttribute("aria-describedby")!)!.textContent).toBe("1 to 1000. Default: 20. Discover in this preview shows at most 20.");
    expect(document.querySelector(".settings-reach")!.textContent).toBe("Discover now: Discover searches Open Library and shows up to 20 results.");
    expect(server.requests.filter((request) => request.method !== "GET")).toEqual([]);
    expect(server.called("GET", SETTINGS)[0]!.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("one explicit save sends only the changed value with the account and token, and shows what the server saved", async () => {
    const server = settingsServer({ read: () => ({ body: settings({}, { search_limit: 50 }) }) });
    await opened(server);
    await userEvent.click(controls().enabled);
    expect(saves(server)).toEqual([]);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe("Metadata settings saved.");
    expect(saves(server).length).toBe(1);
    expect(saves(server)[0]!.body).toEqual({ revision: "0123456789abcdef0123456789abcdef", open_library: { enabled: false } });
    expect(saves(server)[0]!.headers["x-csrf-token"]).toBe("session-token");
    expect(saves(server)[0]!.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(controls().enabled.checked).toBe(false);
    expect(document.querySelector(".settings-reach")!.textContent).toBe("Discover now: Discover does not search, because Open Library is off.");
  });

  test("after a save, Discover asks the server again instead of showing its earlier answer", async () => {
    const server = settingsServer();
    const { history } = renderSettings(server, "/preview/discover");
    await waitFor(() => expect(server.called("GET", DISCOVER).length).toBe(1));
    act(() => history.push("/preview/admin/settings"));
    await screen.findByRole("heading", { name: "Metadata", level: 2 });
    await userEvent.clear(controls().limit);
    await userEvent.type(controls().limit, "7");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe("Metadata settings saved.");
    expect(saves(server)[0]!.body).toEqual({ revision: "0123456789abcdef0123456789abcdef", open_library: { search_limit: 7 } });
    act(() => history.push("/preview/discover"));
    await waitFor(() => expect(server.called("GET", DISCOVER).length).toBe(2));
  });

  test("saving with nothing changed sends nothing", async () => {
    const server = settingsServer();
    await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(screen.getByRole("status").textContent).toBe("There are no changes to save.");
    expect(saves(server)).toEqual([]);
  });

  test("a number outside the range is marked and focused without a request, and typing clears the mark", async () => {
    const server = settingsServer();
    await opened(server);
    for (const typed of ["0", "1001", "2.5", "-4", ""]) {
      await userEvent.clear(controls().limit);
      if (typed) await userEvent.type(controls().limit, typed);
      await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
      const { limit } = controls();
      expect(limit.getAttribute("aria-invalid")).toBe("true");
      expect(document.activeElement).toBe(limit);
      expect(limit.getAttribute("aria-describedby")!.split(" ").map((id) => document.getElementById(id)!.textContent)).toEqual([
        "1 to 1000. Default: 20. Discover in this preview shows at most 20.",
        "⚠ Enter a whole number from 1 to 1000.",
      ]);
      expect(screen.getByRole("status").textContent).toBe("Nothing was saved. Check the marked field.");
    }
    await userEvent.type(controls().limit, "5");
    expect(controls().limit.getAttribute("aria-invalid")).toBe("false");
    expect(saves(server)).toEqual([]);
  });

  test("while saving the button says so and cannot send twice", async () => {
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    const server = settingsServer({
      save: async (request) => {
        await held;
        return { body: saved(request) };
      },
    });
    await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    const pending = await screen.findByRole("button", { name: "Saving…" });
    expect((pending as HTMLButtonElement).disabled).toBe(true);
    expect(pending.getAttribute("aria-busy")).toBe("true");
    await act(async () => {
      (screen.getByRole("checkbox", { name: "Use Open Library" }).closest("form") as HTMLFormElement).requestSubmit();
    });
    expect(saves(server).length).toBe(1);
    await act(async () => release());
    expect((await screen.findByRole("status")).textContent).toBe("Metadata settings saved.");
  });

  test("unsaved edits survive a session check that hides the form, and are saved afterwards", async () => {
    let hold: Promise<void> | null = null;
    const server = settingsServer();
    server.on("GET", SESSION, async () => {
      if (hold) await hold;
      return { body: session({ admin: { url: "/admin" } }) };
    });
    const { services } = await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.clear(controls().limit);
    await userEvent.type(controls().limit, "7");
    let release!: () => void;
    hold = new Promise<void>((resolve) => (release = resolve));
    await act(async () => {
      services.revalidate();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(screen.queryByRole("checkbox")).toBeNull();
    await act(async () => release());
    await screen.findByRole("checkbox", { name: "Use Open Library" });
    expect(controls().enabled.checked).toBe(false);
    expect(controls().limit.value).toBe("7");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe("Metadata settings saved.");
    expect(saves(server)[0]!.body).toEqual({ revision: "0123456789abcdef0123456789abcdef", open_library: { enabled: false, search_limit: 7 } });
  });

  test("an edit keeps the revision it was made against, so values refreshed meanwhile are never overwritten silently", async () => {
    let revision = "0123456789abcdef0123456789abcdef";
    const server = settingsServer({
      read: () => ({ body: settings({ revision }, revision.startsWith("0") ? {} : { search_limit: 5 }) }),
      save: (request) => ((request.body as { revision: string }).revision === revision ? { body: saved(request) } : { status: 409, body: { ...settings({ revision }, { search_limit: 5 }), error: "settings_conflict" } }),
    });
    const { services } = await opened(server);
    await userEvent.click(controls().enabled);
    revision = "22222222222222222222222222222222";
    await act(async () => services.revalidate());
    await waitFor(() => expect(controls().limit.value).toBe("5"));
    expect(controls().enabled.checked).toBe(false);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toContain("These settings were changed somewhere else while you were editing.");
    expect(saves(server)[0]!.body).toEqual({ revision: "0123456789abcdef0123456789abcdef", open_library: { enabled: false } });
    expect(controls().enabled.checked).toBe(true);
  });

  test("after a session check the page asks for the settings again instead of showing what it had", async () => {
    let limit = 20;
    const server = settingsServer({ read: () => ({ body: settings({}, { search_limit: limit }) }) });
    const { services } = await opened(server);
    expect(controls().limit.value).toBe("20");
    const reads = server.called("GET", SETTINGS).length;
    limit = 7;
    await act(async () => services.revalidate());
    await waitFor(() => expect(controls().limit.value).toBe("7"));
    expect(server.called("GET", SETTINGS).length).toBe(reads + 1);
  });

  test("a save answered after the page was left and the role removed is never shown on return", async () => {
    let admin = true;
    let releaseSave!: () => void;
    let releaseRead!: () => void;
    const saveHeld = new Promise<void>((resolve) => (releaseSave = resolve));
    const readHeld = new Promise<void>((resolve) => (releaseRead = resolve));
    const server = settingsServer({
      admin: () => admin,
      read: () => ({ body: settings() }),
      save: async (request) => {
        await saveHeld;
        return { body: saved(request) };
      },
    });
    server.on("GET", SETTINGS, async () => {
      if (admin) return { body: settings() };
      await readHeld;
      return error(404, "not_found");
    });
    const { history } = await opened(server);
    await userEvent.clear(controls().limit);
    await userEvent.type(controls().limit, "7");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    act(() => history.push("/preview/library"));
    await screen.findByRole("heading", { name: "Library", level: 1 });
    admin = false;
    act(() => history.back());
    await screen.findByRole("heading", { name: "Server settings", level: 1 });
    const shown: boolean[] = [];
    const observer = new MutationObserver(() => shown.push(Boolean(document.querySelector("input[name=search_limit]"))));
    observer.observe(document.body, { childList: true, subtree: true, attributes: true });
    await act(async () => {
      releaseSave();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(screen.queryByRole("textbox", { name: "Results per search" })).toBeNull();
    await act(async () => releaseRead());
    expect(await screen.findByRole("heading", { name: "This account's access changed", level: 1 }, { timeout: 8000 })).toBeTruthy();
    observer.disconnect();
    expect(shown.some(Boolean)).toBe(false);
  }, 20_000);

  test("an edit made while a save is pending is saved next against the revision that save produced", async () => {
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    const server = settingsServer({
      save: async (request) => {
        if (saves(server).length === 1) await held;
        return { body: saved(request) };
      },
    });
    await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    await screen.findByRole("button", { name: "Saving…" });
    await userEvent.clear(controls().limit);
    await userEvent.type(controls().limit, "7");
    await act(async () => release());
    expect((await screen.findByText("The earlier change was saved. Your newer change is not saved yet.")).textContent).toBeTruthy();
    expect(controls().limit.value).toBe("7");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(await screen.findByText("Metadata settings saved.")).toBeTruthy();
    expect(saves(server)[1]!.body).toEqual({ revision: "fedcba9876543210fedcba9876543210", open_library: { search_limit: 7 } });
  });

  test("Discover asks again after a repair instead of keeping its earlier refusal", async () => {
    const server = settingsServer({ read: () => ({ body: settings({}, { search_limit: null }, { search: "settings_unreadable", result_limit: null }) }) });
    let repaired = false;
    server.on("GET", DISCOVER, () =>
      repaired ? { body: { account: ACCOUNT, provider: { name: "Open Library", url: "https://openlibrary.org" }, search: "available", query: null, items: [] } } : error(501, "unsupported_stored_value"),
    );
    const { history } = renderSettings(server, "/preview/discover");
    await waitFor(() => expect(server.called("GET", DISCOVER).length).toBe(1));
    await screen.findByRole("alert");
    act(() => history.push("/preview/admin/settings"));
    await screen.findByRole("heading", { name: "Metadata", level: 2 });
    repaired = true;
    await userEvent.type(controls().limit, "12");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    await screen.findByText("Metadata settings saved.");
    act(() => history.push("/preview/discover"));
    await waitFor(() => expect(server.called("GET", DISCOVER).length).toBe(2));
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
  });

  test("a save the server confirmed with an unreadable answer is reported as unknown, not as unchanged", async () => {
    const server = settingsServer({ save: () => ({ status: 200, body: { saved: true } }) });
    await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe(
      "Shelfarr could not confirm whether the settings were saved. Reload the page to see what the server has, and save again if needed.",
    );
  });

  test("a first read overtaken by a session check is never shown; the read after the check is", async () => {
    let limit = 20;
    let releaseFirst!: () => void;
    const firstHeld = new Promise<void>((resolve) => (releaseFirst = resolve));
    let reads = 0;
    const server = settingsServer();
    server.on("GET", SETTINGS, async () => {
      reads += 1;
      const answer = { body: settings({}, { search_limit: limit }) };
      if (reads === 1) await firstHeld;
      return answer;
    });
    const { services } = renderSettings(server);
    await waitFor(() => expect(reads).toBe(1));
    limit = 7;
    await act(async () => services.revalidate());
    await waitFor(() => expect(reads).toBe(2));
    await act(async () => releaseFirst());
    await screen.findByRole("heading", { name: "Metadata", level: 2 });
    expect(controls().limit.value).toBe("7");
    await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
    expect(controls().limit.value).toBe("7");
  });

  test("a session check during a pending save reads only after the save, so neither answer replaces a newer one", async () => {
    let stored = { enabled: true, limit: 20 };
    let releaseSave!: () => void;
    const saveHeld = new Promise<void>((resolve) => (releaseSave = resolve));
    const server = settingsServer({
      read: () => ({ body: settings({}, { enabled: stored.enabled, search_limit: stored.limit }) }),
      save: async (request) => {
        stored = { ...stored, enabled: false };
        const answer = saved(request);
        await saveHeld;
        return { body: answer };
      },
    });
    const { services } = await opened(server);
    const reads = server.called("GET", SETTINGS).length;
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    stored = { ...stored, limit: 5 };
    await act(async () => services.revalidate());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 50)));
    expect(server.called("GET", SETTINGS).length).toBe(reads);
    await act(async () => releaseSave());
    expect(await screen.findByText("Metadata settings saved.")).toBeTruthy();
    await waitFor(() => expect(controls().limit.value).toBe("5"));
    expect(controls().enabled.checked).toBe(false);
    expect(server.called("GET", SETTINGS).length).toBe(reads + 1);
  });

  test("a member's session checks never ask for the settings", async () => {
    const server = settingsServer({ admin: () => false });
    const { services } = renderSettings(server);
    await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 });
    const checks = server.called("GET", SESSION).length;
    await act(async () => services.revalidate());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 200)));
    expect(server.called("GET", SETTINGS).length).toBe(0);
    expect(server.called("GET", SESSION).length).toBe(checks + 1);
  });

  test("a server without the settings route is asked once, checked once, and not asked again on the next check", async () => {
    const server = settingsServer({ read: () => error(404, "not_found") });
    const { services } = renderSettings(server);
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 })).toBeTruthy();
    await act(async () => new Promise((resolve) => setTimeout(resolve, 200)));
    await act(async () => services.revalidate());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 200)));
    expect(server.called("GET", SETTINGS).length).toBe(1);
    expect(server.called("GET", SESSION).length).toBeLessThanOrEqual(3);
  });

  test("a save that fails while the session is being checked reads again only after the check", async () => {
    let limit = 20;
    let hold: Promise<void> | null = null;
    let releaseSave!: () => void;
    const saveHeld = new Promise<void>((resolve) => (releaseSave = resolve));
    const server = settingsServer({
      read: () => ({ body: settings({}, { search_limit: limit }) }),
      save: async () => {
        await saveHeld;
        return error(503, "database_unavailable");
      },
    });
    server.on("GET", SESSION, async () => {
      if (hold) await hold;
      return { body: session({ admin: { url: "/admin" } }) };
    });
    const { services } = await opened(server);
    const reads = server.called("GET", SETTINGS).length;
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    let releaseCheck!: () => void;
    hold = new Promise<void>((resolve) => (releaseCheck = resolve));
    await act(async () => {
      services.revalidate();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    await act(async () => {
      releaseSave();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(server.called("GET", SETTINGS).length).toBe(reads);
    limit = 7;
    await act(async () => releaseCheck());
    await waitFor(() => expect(controls().limit.value).toBe("7"));
    expect(server.called("GET", SETTINGS).length).toBe(reads + 1);
    expect(screen.getByText("Shelfarr could not confirm whether the settings were saved. Reload the page to see what the server has, and save again if needed.")).toBeTruthy();
  });

  test("of two retries only the one started last is shown", async () => {
    const releases: (() => void)[] = [];
    let reads = 0;
    const server = settingsServer();
    server.on("GET", SETTINGS, async () => {
      reads += 1;
      if (reads === 1) return error(503, "database_unavailable");
      const limit = reads === 2 ? 20 : 7;
      await new Promise<void>((resolve) => releases.push(resolve));
      return { body: settings({}, { search_limit: limit }) };
    });
    renderSettings(server);
    const retry = await screen.findByRole("button", { name: "Try again" }, { timeout: 8000 });
    await userEvent.click(retry);
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(releases.length).toBe(2));
    await act(async () => releases[1]!());
    await screen.findByRole("heading", { name: "Metadata", level: 2 });
    await act(async () => {
      releases[0]!();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(controls().limit.value).toBe("7");
  }, 15_000);

  test("an unknown save result stays announced when the read after it fails", async () => {
    const server = settingsServer({ save: () => ({ status: 200, body: { saved: true } }) });
    await opened(server);
    server.on("GET", SETTINGS, () => error(503, "database_unavailable"));
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(await screen.findByRole("button", { name: "Try again" }, { timeout: 8000 })).toBeTruthy();
    expect(screen.getByText("Shelfarr could not confirm whether the settings were saved. Reload the page to see what the server has, and save again if needed.")).toBeTruthy();
  }, 15_000);

  test("a save refused as not found checks the session once and does not read again", async () => {
    const server = settingsServer({ save: () => error(404, "not_found") });
    await opened(server);
    const reads = server.called("GET", SETTINGS).length;
    const checks = server.called("GET", SESSION).length;
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 })).toBeTruthy();
    await act(async () => new Promise((resolve) => setTimeout(resolve, 300)));
    expect(server.called("GET", SETTINGS).length).toBe(reads);
    expect(server.called("GET", SESSION).length).toBe(checks + 1);
  });

  test("a read left behind on leaving the page is cancelled, so its late refusal cannot sign out the page now open", async () => {
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    const server = settingsServer();
    server.on("GET", SETTINGS, async () => {
      await held;
      return error(401, "signed_out");
    });
    const { services, history } = renderSettings(server);
    await waitFor(() => expect(server.called("GET", SETTINGS).length).toBe(1));
    act(() => history.push("/preview/library"));
    await screen.findByRole("heading", { name: "Library", level: 1 });
    await act(async () => services.revalidate());
    await act(async () => {
      release();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    expect(services.guard.isActive()).toBe(true);
    expect(screen.getByRole("heading", { name: "Library", level: 1 })).toBeTruthy();
    expect(server.called("GET", SETTINGS)[0]!.signal?.aborted).toBe(true);
  });

  test("a change saved elsewhere first is a conflict: nothing is overwritten and the saved values are shown", async () => {
    const server = settingsServer({ save: () => ({ status: 409, body: { ...settings({ revision: "11111111111111111111111111111111" }, { search_limit: 5 }, { result_limit: 5 }), error: "settings_conflict" } }) });
    await opened(server);
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe(
      "These settings were changed somewhere else while you were editing. Nothing was saved. Check the saved values and make your change again.",
    );
    expect(controls().enabled.checked).toBe(true);
    expect(controls().limit.value).toBe("5");
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(saves(server)[1]!.body).toEqual({ revision: "11111111111111111111111111111111", open_library: { enabled: false } });
  });

  test("a value the server refuses is marked on its field", async () => {
    const server = settingsServer({ save: () => ({ status: 422, body: { account: ACCOUNT, error: "invalid_settings", errors: { search_limit: ["must be a whole number from 1 to 1000"] } } }) });
    await opened(server);
    await userEvent.clear(controls().limit);
    await userEvent.type(controls().limit, "30");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe("Nothing was saved. Check the marked field.");
    expect(controls().limit.getAttribute("aria-invalid")).toBe("true");
    expect(document.activeElement).toBe(controls().limit);
  });

  test("an unanswered save says the result is unknown and asks the server for the saved values again", async () => {
    const server = settingsServer({ save: () => error(503, "database_unavailable") });
    await opened(server);
    const reads = server.called("GET", SETTINGS).length;
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect((await screen.findByRole("status")).textContent).toBe(
      "Shelfarr could not confirm whether the settings were saved. Reload the page to see what the server has, and save again if needed.",
    );
    await waitFor(() => expect(server.called("GET", SETTINGS).length).toBeGreaterThan(reads));
    expect(saves(server).length).toBe(1);
  });

  test("a save refused because the role is gone checks the session and locks the page", async () => {
    let admin = true;
    const server = settingsServer({ admin: () => admin, save: () => error(404, "not_found") });
    await opened(server);
    admin = false;
    await userEvent.click(controls().enabled);
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    expect(await screen.findByRole("heading", { name: "This account's access changed", level: 1 }, { timeout: 8000 })).toBeTruthy();
    expect(saves(server).length).toBe(1);
  }, 20_000);

  test("unreadable saved values are said so, and only a value the admin enters replaces them", async () => {
    const server = settingsServer({ read: () => ({ body: settings({}, { enabled: null, search_limit: null }, { search: "settings_unreadable", result_limit: null }) }) });
    await opened(server);
    const { enabled, limit } = controls();
    expect(enabled.checked).toBe(false);
    expect(limit.value).toBe("");
    expect(document.getElementById(enabled.getAttribute("aria-describedby")!)!.textContent).toBe(
      "⚠ The saved choice cannot be read. Tick or clear this box and save to replace it. Searches openlibrary.org for book details. Default: on.",
    );
    expect(document.getElementById(limit.getAttribute("aria-describedby")!)!.textContent).toContain("⚠ The saved number cannot be read. Enter a number and save to replace it.");
    expect(document.querySelector(".settings-reach")!.textContent).toBe("Discover now: Discover cannot search, because a saved setting it reads cannot be read.");
    await userEvent.type(limit, "12");
    await userEvent.click(screen.getByRole("button", { name: "Save metadata settings" }));
    await screen.findByText("Metadata settings saved.");
    expect(saves(server)[0]!.body).toEqual({ revision: "0123456789abcdef0123456789abcdef", open_library: { search_limit: 12 } });
  });

  test("each Discover state is described in plain words", async () => {
    const cases: [Partial<MetadataSettings["discover"]>, string][] = [
      [{ search: "server_off", result_limit: null }, "Discover search is switched off for this server when it starts, so Discover sends nothing to Open Library whatever is saved here."],
      [{ search: "provider_not_selected", result_limit: null }, "Discover does not search, because the classic settings choose a different metadata source."],
      [{ search: "provider_paused", result_limit: 20, retry_after: 300 }, "Open Library is paused after errors or too many requests, for about 5 minutes. Saving here does not end the pause."],
      [{ search: "provider_paused", result_limit: 20 }, "Open Library is paused after errors or too many requests. Saving here does not end the pause."],
      [{ search: "available", result_limit: 0 }, "Discover finds nothing, because the saved number is 0 or less."],
    ];
    for (const [discover, text] of cases) {
      const server = settingsServer({ read: () => ({ body: settings({}, {}, discover) }) });
      const { view } = await opened(server);
      expect(document.querySelector(".settings-reach")!.textContent).toBe(`Discover now: ${text}`);
      view.unmount();
    }
  });

  test("a member asks for no settings and is told the page is for administrators", async () => {
    const server = settingsServer({ admin: () => false });
    renderSettings(server);
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page", level: 2 })).toBeTruthy();
    expect(screen.queryByRole("checkbox")).toBeNull();
    expect(server.called("GET", SETTINGS).length).toBe(0);
  });

  test("settings seen before are never shown again on return after a demotion, and the page locks", async () => {
    let admin = true;
    const server = settingsServer({ admin: () => admin, read: () => (admin ? { body: settings({}, { search_limit: 777 }) } : error(404, "not_found")) });
    const { history } = await opened(server);
    expect(controls().limit.value).toBe("777");
    act(() => history.push("/preview/library"));
    await screen.findByRole("heading", { name: "Library", level: 1 });
    admin = false;
    const shown: boolean[] = [];
    const observer = new MutationObserver(() => shown.push(Boolean(document.querySelector('input[value="777"]'))));
    observer.observe(document.body, { childList: true, subtree: true, attributes: true });
    act(() => history.push("/preview/admin/settings"));
    expect(await screen.findByRole("heading", { name: "This account's access changed", level: 1 }, { timeout: 8000 })).toBeTruthy();
    observer.disconnect();
    expect(shown.length).toBeGreaterThan(0);
    expect(shown.some(Boolean)).toBe(false);
  }, 20_000);

  test("signing in from the settings address explains where it returns", async () => {
    const server = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => ({ body: signedOut() }));
    renderGo({ server, view: "server_settings", url: "/preview/admin/settings" });
    expect(await screen.findByText("Sign in to change the server settings. You will come straight back to them.")).toBeTruthy();
  });
});
