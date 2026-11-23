import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { SettingField } from "../src/server/contract";
import { setupStateSchema, type SetupCard, type SetupState, type SetupStepId } from "../src/server/setup/contract";
import { ACCOUNT, deferred, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const STEPS: { id: SetupStepId; label: string }[] = [
  { id: "prowlarr", label: "Prowlarr" },
  { id: "qbittorrent", label: "qBittorrent" },
  { id: "folders", label: "Folders" },
  { id: "audiobookshelf", label: "Audiobookshelf" },
  { id: "search", label: "Search" },
];

function field(key: string, overrides: Partial<SettingField> = {}): SettingField {
  return { key, label: key, description: `About ${key}.`, input: "text", value: "", ...overrides };
}

function card(id: string, fields: SettingField[], overrides: Partial<SetupCard> = {}): SetupCard {
  return { id, phase: null, title: id, summary: null, submit: "Test and continue", collapsed: false, fields, ...overrides };
}

function state(step: SetupStepId, cards: SetupCard[], overrides: Partial<SetupState> = {}): SetupState {
  const index = STEPS.findIndex((entry) => entry.id === step);
  return {
    account: ACCOUNT,
    step,
    steps: STEPS,
    previous: index > 0 ? STEPS[index - 1]!.id : null,
    last: step === "search",
    completed: false,
    title: STEPS[index]!.label,
    summary: `About ${step}.`,
    warnings: [],
    library_error: null,
    cards,
    ...overrides,
  };
}

const prowlarr = () =>
  state("prowlarr", [
    card("prowlarr", [
      field("url", { label: "Prowlarr address", input: "url", value: "http://prowlarr:9696" }),
      field("api_key", { label: "Prowlarr API key", input: "secret", value: null, configured: true }),
    ]),
  ]);

const qbittorrent = () => state("qbittorrent", [card("qbittorrent", [field("url", { label: "qBittorrent address", input: "url", value: "" }), field("password", { label: "Password", input: "secret", value: null, configured: false })])]);

const search = () =>
  state("search", [
    card(
      "search",
      [
        field("immediate_search_enabled", { label: "Start searching as soon as a request is created", input: "toggle", value: true }),
        field("auto_select_enabled", { label: "Download the best match automatically", input: "toggle", value: false }),
      ],
      { submit: "Finish", title: "Starting requests" },
    ),
  ]);

function setupServer(states: Partial<Record<SetupStepId, SetupState>> = {}, sessionOverrides: object = ADMIN): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(sessionOverrides) }))
    .on("GET", /\/api\/v1\/admin\/setup(\?|$)/, (request) => {
      const step = (new URL(request.path, "http://shelf.test").searchParams.get("step") ?? "prowlarr") as SetupStepId;
      return { body: states[step] ?? prowlarr() };
    });
}

function cardSection(name: string): HTMLElement {
  return screen.getByRole("heading", { name, level: 3 }).closest("section, details") as HTMLElement;
}

describe("Setup in the Rails preview", () => {
  test("the fixtures match the setup contract", () => {
    for (const fixture of [prowlarr(), qbittorrent(), search()]) expect(setupStateSchema.safeParse(fixture).success).toBe(true);
  });

  test("a member is told setup is for administrators and nothing is asked of the server", async () => {
    const server = standardServer();
    renderApp({ server, url: "/sub/preview/server/setup" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
    expect(server.requests.filter((request) => request.path.includes("/admin/"))).toEqual([]);
  });

  test("an administrator whose role was taken away is refused by the server and sees the same message", async () => {
    const server = standardServer()
      .on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }))
      .on("GET", /\/api\/v1\/admin\/setup/, () => ({ status: 404, body: { error: "not_found" } }));
    renderApp({ server, url: "/sub/preview/server/setup" });
    expect(await screen.findByRole("heading", { name: "Only administrators can see this page" })).toBeTruthy();
  });

  test("the first step shows every step, keeps a saved key write-only and moves on with what was typed", async () => {
    const next = { ...qbittorrent(), title: "qBittorrent" };
    const server = setupServer().on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => ({
      body: { account: ACCOUNT, outcome: { tone: "success", message: "Prowlarr connected." }, alert: null, completed: false, setup: next },
    }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });

    expect(await screen.findByRole("heading", { name: "Set up Shelfarr", level: 1 })).toBeTruthy();
    const steps = await screen.findByRole("navigation", { name: "Setup steps" });
    expect(within(steps).getAllByRole("listitem").map((item) => [item.textContent, item.firstElementChild!.getAttribute("aria-current"), item.firstElementChild!.getAttribute("href")])).toEqual([
      ["1Prowlarr", "step", null],
      ["2qBittorrent", null, "/sub/preview/server/setup?step=qbittorrent"],
      ["3Folders", null, "/sub/preview/server/setup?step=folders"],
      ["4Audiobookshelf", null, "/sub/preview/server/setup?step=audiobookshelf"],
      ["5Search", null, "/sub/preview/server/setup?step=search"],
    ]);
    expect(screen.getByText("Step 1 of 5")).toBeTruthy();
    expect(document.activeElement).not.toBe(screen.getByRole("heading", { name: "Prowlarr", level: 2 }));
    expect(screen.queryByRole("link", { name: "Back" })).toBeNull();
    const prowlarrCard = cardSection("prowlarr");
    expect(within(prowlarrCard).getByRole("button", { name: "Replace" })).toBeTruthy();
    expect(within(prowlarrCard).queryByLabelText("Prowlarr API key")).toBeNull();

    const address = within(prowlarrCard).getByLabelText("Prowlarr address");
    await userEvent.clear(address);
    await userEvent.type(address, "http://indexer:9696");
    expect(within(prowlarrCard).getByText("Unsaved changes")).toBeTruthy();
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Test and continue" }));

    expect(await screen.findByText("Prowlarr connected.")).toBeTruthy();
    const put = server.called("PUT", /\/admin\/setup\/steps\/prowlarr$/)[0]!;
    expect(put.body).toEqual({ values: { url: "http://indexer:9696", api_key: "" } });
    expect(put.headers["x-csrf-token"]).toBe("token-123");
    expect(put.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(router.state.location.search).toEqual({ step: "qbittorrent" });
    const heading = screen.getByRole("heading", { name: "qBittorrent", level: 2 });
    await waitFor(() => expect(document.activeElement).toBe(heading));
    expect(within(screen.getByRole("navigation", { name: "Setup steps" })).getByText("qBittorrent").getAttribute("aria-current")).toBe("step");
    expect(screen.getByRole("link", { name: "Back" }).getAttribute("href")).toBe("/sub/preview/server/setup?step=prowlarr");
    expect(server.called("GET", /\/admin\/setup\?step=qbittorrent/)).toEqual([]);
  });

  test("a refused connection keeps the typed values, says why and moves focus to the reason", async () => {
    const server = setupServer().on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => ({
      status: 422,
      body: { account: ACCOUNT, error: "setup_rejected", message: "Prowlarr rejected the API key. Copy it from Prowlarr under Settings > General." },
    }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup?step=prowlarr" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Replace" }));
    await userEvent.type(within(prowlarrCard).getByLabelText("Prowlarr API key"), "wrong-key");
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Test and continue" }));

    const alert = await within(prowlarrCard).findByRole("alert");
    expect(alert.textContent).toBe("⚠ Prowlarr rejected the API key. Copy it from Prowlarr under Settings > General.");
    await waitFor(() => expect(document.activeElement).toBe(alert));
    expect((within(prowlarrCard).getByLabelText("Prowlarr API key") as HTMLInputElement).value).toBe("wrong-key");
    expect(router.state.location.search).toEqual({ step: "prowlarr" });
    expect(server.called("PUT", /prowlarr$/)[0]!.body).toEqual({ values: { url: "http://prowlarr:9696", api_key: "wrong-key" } });
  });

  test("an unconfirmed save says so and stays on the step", async () => {
    const server = setupServer().on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => ({ status: 502, body: {} }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Test and continue" }));
    expect((await within(prowlarrCard).findByRole("alert")).textContent).toBe(
      "⚠ Shelfarr could not confirm whether this step was saved. Reload the page to see what the server has, and try again if needed.",
    );
    expect(router.state.location.search).toEqual({});
  });

  test("Audiobookshelf stays on its step after connecting and then offers its libraries, with Not now", async () => {
    const connect = state("audiobookshelf", [
      card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url" }), field("api_key", { label: "Audiobookshelf API token", input: "secret", value: null, configured: false })], {
        phase: "connection",
        title: "Audiobookshelf",
      }),
    ]);
    const connected = state("audiobookshelf", [
      card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "lib-audio", placeholder: "Not now" }), field("ebook_library_id", { label: "Ebook library", input: "library", value: "", placeholder: "Not now" })], {
        phase: "libraries",
        title: "Libraries",
        submit: "Save and continue",
        libraries: [
          { id: "lib-audio", name: "Audiobooks", media_type: "book" },
          { id: "lib-ebooks", name: "Ebooks", media_type: "book" },
        ],
      }),
      card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" }), field("api_key", { label: "Audiobookshelf API token", input: "secret", value: null, configured: true })], {
        phase: "connection",
        title: "Change the Audiobookshelf connection",
        submit: "Test and save connection",
        collapsed: true,
      }),
    ]);
    const server = setupServer({ audiobookshelf: connect })
      .on("PUT", /\/admin\/setup\/steps\/audiobookshelf$/, (request) =>
        (request.body as { values: { phase: string } }).values.phase === "connection"
          ? { body: { account: ACCOUNT, outcome: { tone: "success", message: "Audiobookshelf connected. Choose the libraries Shelfarr should scan." }, alert: null, completed: false, setup: connected } }
          : { body: { account: ACCOUNT, outcome: { tone: "success", message: "Audiobookshelf libraries saved." }, alert: null, completed: false, setup: search() } },
      );
    const { router } = renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });

    const connection = await waitFor(() => cardSection("Audiobookshelf"));
    await userEvent.type(within(connection).getByLabelText("Audiobookshelf address"), "http://abs:13378");
    await userEvent.type(within(connection).getByLabelText("Audiobookshelf API token"), "abs-token");
    await userEvent.click(within(connection).getByRole("button", { name: "Test and continue" }));

    expect(await screen.findByText("Audiobookshelf connected. Choose the libraries Shelfarr should scan.")).toBeTruthy();
    expect(server.called("PUT", /audiobookshelf$/)[0]!.body).toEqual({ values: { url: "http://abs:13378", api_key: "abs-token", phase: "connection" } });
    expect(router.state.location.search).toEqual({ step: "audiobookshelf" });
    const libraries = cardSection("Libraries");
    const ebook = within(libraries).getByLabelText("Ebook library") as HTMLSelectElement;
    expect(Array.from(ebook.options).map((option) => option.textContent)).toEqual(["Not now", "Audiobooks (book)", "Ebooks (book)"]);
    expect((within(libraries).getByLabelText("Audiobook library") as HTMLSelectElement).value).toBe("lib-audio");
    const change = cardSection("Change the Audiobookshelf connection") as HTMLDetailsElement;
    expect(change.tagName).toBe("DETAILS");
    expect(change.open).toBe(false);

    await userEvent.click(within(libraries).getByRole("button", { name: "Save and continue" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ step: "search" }));
    expect(server.called("PUT", /audiobookshelf$/)[1]!.body).toEqual({ values: { audiobook_library_id: "lib-audio", ebook_library_id: "", phase: "libraries" } });
  });

  test("warnings never block, and the last step's Finish goes to the library with the chosen switches", async () => {
    const finishing = { ...search(), warnings: ["qBittorrent saves to /mnt/torrents, which is not inside /downloads or does not exist in this container."] };
    const server = setupServer({ search: finishing }).on("PUT", /\/admin\/setup\/steps\/search$/, () => ({
      body: { account: ACCOUNT, outcome: { tone: "success", message: "Setup complete." }, alert: null, completed: true, setup: null },
    }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup?step=search" });

    expect(await screen.findByText(/qBittorrent saves to \/mnt\/torrents/)).toBeTruthy();
    expect(screen.getByRole("link", { name: "review the folders" }).getAttribute("href")).toBe("/sub/preview/server/setup?step=folders");
    expect(screen.queryByRole("button", { name: "Skip this step" })).toBeNull();
    await userEvent.click(screen.getByLabelText("Download the best match automatically"));
    await userEvent.click(screen.getByLabelText("Start searching as soon as a request is created"));
    await userEvent.click(screen.getByRole("button", { name: "Finish" }));

    await waitFor(() => expect(router.state.location.pathname).toBe("/library"));
    expect(server.called("PUT", /search$/)[0]!.body).toEqual({ values: { immediate_search_enabled: false, auto_select_enabled: true } });
  });

  test("skipping a step moves on without saving, and skipping setup goes to the library", async () => {
    const server = setupServer()
      .on("POST", /\/admin\/setup\/skip$/, (request) =>
        (request.body as { exit: boolean }).exit ? { body: { account: ACCOUNT, completed: true, setup: null } } : { body: { account: ACCOUNT, completed: false, setup: qbittorrent() } },
      );
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });

    await userEvent.click(await screen.findByRole("button", { name: "Skip this step" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ step: "qbittorrent" }));
    expect(server.called("POST", /skip$/)[0]!.body).toEqual({ step: "prowlarr", exit: false });
    expect(server.called("PUT", /setup\/steps/)).toEqual([]);

    await userEvent.click(screen.getByRole("button", { name: "Skip setup" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/library"));
    expect(server.called("POST", /skip$/)[1]!.body).toEqual({ step: "qbittorrent", exit: true });
  });

  test("leaving a step with typed changes asks first, and staying keeps them", async () => {
    const server = setupServer({ qbittorrent: qbittorrent() });
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.type(within(prowlarrCard).getByLabelText("Prowlarr address"), "/extra");

    await userEvent.click(within(screen.getByRole("navigation", { name: "Setup steps" })).getByRole("link", { name: "qBittorrent" }));
    const dialog = await screen.findByRole("dialog", { name: "Leave without saving?" });
    await userEvent.click(within(dialog).getByRole("button", { name: "Stay and keep editing" }));
    expect(router.state.location.search).toEqual({});
    expect((within(cardSection("prowlarr")).getByLabelText("Prowlarr address") as HTMLInputElement).value).toBe("http://prowlarr:9696/extra");

    await userEvent.click(within(screen.getByRole("navigation", { name: "Setup steps" })).getByRole("link", { name: "qBittorrent" }));
    await userEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Leave and discard" }));
    await waitFor(() => expect(router.state.location.search).toEqual({ step: "qbittorrent" }));
  });

  test("the old setup address opens the same step here", async () => {
    const server = setupServer({ folders: state("folders", [card("folders", [field("download_local_path", { label: "Download folder in this container", value: "/downloads" })], { submit: "Save and continue" })]) });
    const { router } = renderApp({ server, url: "/sub/preview/admin/setup_wizard?step=folders" });
    expect(await screen.findByRole("heading", { name: "Folders", level: 2 })).toBeTruthy();
    expect(router.state.location.pathname).toBe("/server/setup");
    expect(router.state.location.search).toEqual({ step: "folders" });
  });

  test("System offers Run setup again, which reopens the first step", async () => {
    const settings = {
      account: ACCOUNT,
      categories: [{ id: "system", title: "System", summary: "Health checks.", groups: [] }],
      notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "", redirect_uri: "", redirect_uri_acceptable: true } },
      roles: [],
    };
    const server = setupServer()
      .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settings }))
      .on("POST", /\/admin\/setup\/restart$/, () => ({ body: { account: ACCOUNT, completed: false, setup: prowlarr() } }));
    const { router } = renderApp({ server, url: "/sub/preview/server/system" });

    const setupCard = await waitFor(() => cardSection("Setup"));
    await userEvent.click(within(setupCard).getByRole("button", { name: "Run setup again" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/server/setup"));
    expect(router.state.location.search).toEqual({ step: "prowlarr" });
    expect(server.called("POST", /restart$/)[0]!.headers["x-csrf-token"]).toBe("token-123");
    expect(await screen.findByRole("heading", { name: "Prowlarr", level: 2 })).toBeTruthy();
    expect(server.called("GET", /\/admin\/setup/)).toEqual([]);
  });

  test("the overview offers setup only while the server says nothing is set up", async () => {
    const overview = (pending: boolean) => ({
      account: ACCOUNT,
      counts: { users: 1, books: 0, active_requests: 0, attention_requests: 0 },
      services: ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"].map((service) => ({ service, status: null, checked_at: null })),
      setup: { pending, completed: !pending },
    });
    let pending = true;
    const server = setupServer().on("GET", /\/api\/v1\/admin\/overview$/, () => ({ body: overview(pending) }));
    const { router } = renderApp({ server, url: "/sub/preview/server" });

    const reminder = (await screen.findByRole("heading", { name: "Shelfarr is not set up yet", level: 2 })).closest("section")!;
    expect(within(reminder).getByRole("link", { name: "Start setup" }).getAttribute("href")).toBe("/sub/preview/server/setup");
    await userEvent.click(within(reminder).getByRole("link", { name: "Start setup" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/server/setup"));

    cleanup();
    pending = false;
    renderApp({ server, url: "/sub/preview/server" });
    expect(await screen.findByRole("heading", { name: "System health", level: 2 })).toBeTruthy();
    expect(screen.queryByRole("heading", { name: "Shelfarr is not set up yet" })).toBeNull();
  });

  test("a background read of the same step keeps what is being typed", async () => {
    const server = setupServer();
    const { services } = renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.type(within(prowlarrCard).getByLabelText("Prowlarr address"), "/typed");

    await services.queryClient.invalidateQueries();
    await waitFor(() => expect(server.called("GET", /\/admin\/setup/).length).toBe(2));

    expect((within(cardSection("prowlarr")).getByLabelText("Prowlarr address") as HTMLInputElement).value).toBe("http://prowlarr:9696/typed");
    expect(within(cardSection("prowlarr")).getByText("Unsaved changes")).toBeTruthy();
  });

  test("while a step is being saved, nothing else on the page can write", async () => {
    const held = deferred<{ body: unknown }>();
    const server = setupServer()
      .on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => held.promise)
      .on("POST", /\/admin\/setup\/skip$/, () => ({ body: { account: ACCOUNT, completed: true, setup: null } }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Test and continue" }));

    await waitFor(() => expect((screen.getByRole("button", { name: "Skip setup" }) as HTMLButtonElement).disabled).toBe(true));
    expect((screen.getByRole("button", { name: "Skip this step" }) as HTMLButtonElement).disabled).toBe(true);
    await userEvent.click(screen.getByRole("button", { name: "Skip setup" }));
    expect(server.called("POST", /skip$/)).toEqual([]);

    held.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Prowlarr connected." }, alert: null, completed: false, setup: qbittorrent() } });
    await waitFor(() => expect(router.state.location.search).toEqual({ step: "qbittorrent" }));
    expect(server.called("PUT", /prowlarr$/).length).toBe(1);
  });

  test("skipping with typed changes asks first, and only leaving sends the skip", async () => {
    const server = setupServer().on("POST", /\/admin\/setup\/skip$/, () => ({ body: { account: ACCOUNT, completed: true, setup: null } }));
    const { router } = renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.type(within(prowlarrCard).getByLabelText("Prowlarr address"), "/typed");

    await userEvent.click(screen.getByRole("button", { name: "Skip setup" }));
    await userEvent.click(within(await screen.findByRole("dialog", { name: "Leave without saving?" })).getByRole("button", { name: "Stay and keep editing" }));
    expect(server.called("POST", /skip$/)).toEqual([]);
    expect((within(cardSection("prowlarr")).getByLabelText("Prowlarr address") as HTMLInputElement).value).toBe("http://prowlarr:9696/typed");

    await userEvent.click(screen.getByRole("button", { name: "Skip setup" }));
    await userEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Leave and discard" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/library"));
    expect(server.called("POST", /skip$/)[0]!.body).toEqual({ step: "prowlarr", exit: true });
  });

  test("System offers Continue setup instead while setup is unfinished", async () => {
    const settings = {
      account: ACCOUNT,
      categories: [{ id: "system", title: "System", summary: "Health checks.", groups: [] }],
      notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "", redirect_uri: "", redirect_uri_acceptable: true } },
      roles: [],
    };
    const overview = {
      account: ACCOUNT,
      counts: { users: 1, books: 0, active_requests: 0, attention_requests: 0 },
      services: ["indexer", "download_client", "download_paths", "output_paths", "audiobookshelf", "hardcover"].map((service) => ({ service, status: null, checked_at: null })),
      setup: { pending: false, completed: false },
    };
    const server = setupServer()
      .on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settings }))
      .on("GET", /\/api\/v1\/admin\/overview$/, () => ({ body: overview }));
    const { router } = renderApp({ server, url: "/sub/preview/server/system" });

    const setupCard = await waitFor(() => cardSection("Setup"));
    const link = await within(setupCard).findByRole("link", { name: "Continue setup" });
    expect(within(setupCard).queryByRole("button", { name: "Run setup again" })).toBeNull();
    await userEvent.click(link);
    await waitFor(() => expect(router.state.location.pathname).toBe("/server/setup"));
    expect(server.called("POST", /restart$/)).toEqual([]);
  });

  test("a library choice survives a read where the libraries could not be listed, and still counts as unsaved", async () => {
    const libraries = card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "", placeholder: "Not now" })], {
      phase: "libraries",
      title: "Libraries",
      submit: "Save and continue",
      libraries: [{ id: "lib-audio", name: "Audiobooks", media_type: "book" }],
    });
    const connection = card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Change the Audiobookshelf connection", collapsed: true });
    let reachable = true;
    const server = setupServer().on("GET", /\/admin\/setup\?step=audiobookshelf/, () => ({
      body: reachable ? state("audiobookshelf", [libraries, connection]) : state("audiobookshelf", [{ ...connection, collapsed: false, title: "Audiobookshelf" }], { library_error: "Connection refused" }),
    }));
    const { services, router } = renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });
    await userEvent.selectOptions(await screen.findByLabelText("Audiobook library"), "lib-audio");

    reachable = false;
    await services.queryClient.invalidateQueries();
    expect(await screen.findByText(/did not list libraries: Connection refused/)).toBeTruthy();
    expect(screen.queryByLabelText("Audiobook library")).toBeNull();
    await userEvent.click(within(screen.getByRole("navigation", { name: "Setup steps" })).getByRole("link", { name: "Search" }));
    await userEvent.click(within(await screen.findByRole("dialog", { name: "Leave without saving?" })).getByRole("button", { name: "Stay and keep editing" }));

    reachable = true;
    await services.queryClient.invalidateQueries();
    await waitFor(() => expect((screen.getByLabelText("Audiobook library") as HTMLSelectElement).value).toBe("lib-audio"));
    expect(within(cardSection("Libraries")).getByText("Unsaved changes")).toBeTruthy();
    expect(router.state.location.search).toEqual({ step: "audiobookshelf" });
  });

  test("saving one card while another has changes asks first, and the fields are locked while it saves", async () => {
    const held = deferred<{ status: number; body: unknown }>();
    const libraries = card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "", placeholder: "Not now" })], {
      phase: "libraries",
      title: "Libraries",
      submit: "Save and continue",
      libraries: [{ id: "lib-audio", name: "Audiobooks", media_type: "book" }],
    });
    const connection = card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Change the Audiobookshelf connection", collapsed: true, submit: "Test and save connection" });
    const server = setupServer({ audiobookshelf: state("audiobookshelf", [libraries, connection]) }).on("PUT", /\/admin\/setup\/steps\/audiobookshelf$/, () => held.promise);
    renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });

    const change = await waitFor(() => cardSection("Change the Audiobookshelf connection") as HTMLDetailsElement);
    change.open = true;
    await userEvent.type(within(change).getByLabelText("Audiobookshelf address"), "/other");
    await userEvent.click(within(cardSection("Libraries")).getByRole("button", { name: "Save and continue" }));
    const dialog = await screen.findByRole("dialog", { name: "Leave without saving?" });
    expect(within(dialog).getByText(/One card has changes/)).toBeTruthy();
    await userEvent.click(within(dialog).getByRole("button", { name: "Stay and keep editing" }));
    expect(server.called("PUT", /audiobookshelf$/)).toEqual([]);

    await userEvent.click(within(cardSection("Change the Audiobookshelf connection")).getByRole("button", { name: "Test and save connection" }));
    await waitFor(() => expect(server.called("PUT", /audiobookshelf$/).length).toBe(1));
    expect(within(cardSection("Change the Audiobookshelf connection")).getByLabelText("Audiobookshelf address").closest("fieldset")!.disabled).toBe(true);
    expect(within(cardSection("Libraries")).getByLabelText("Audiobook library").closest("fieldset")!.disabled).toBe(true);
    held.resolve({ status: 422, body: { account: ACCOUNT, error: "setup_rejected", message: "Could not connect to Audiobookshelf." } });
    await waitFor(() => expect(within(cardSection("Change the Audiobookshelf connection")).getByLabelText("Audiobookshelf address").closest("fieldset")!.disabled).toBe(false));
    expect(within(cardSection("Change the Audiobookshelf connection")).getByRole("alert").textContent).toBe("⚠ Could not connect to Audiobookshelf.");
  });

  test("a step left while its save was pending shows the state the save answered with", async () => {
    const held = deferred<{ body: unknown }>();
    const server = setupServer({ qbittorrent: qbittorrent() }).on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => held.promise);
    renderApp({ server, url: "/sub/preview/server/setup" });
    const prowlarrCard = await waitFor(() => cardSection("prowlarr"));
    await userEvent.click(within(prowlarrCard).getByRole("button", { name: "Test and continue" }));
    await userEvent.click(within(screen.getByRole("navigation", { name: "Setup steps" })).getByRole("link", { name: "qBittorrent" }));
    await screen.findByRole("heading", { name: "qBittorrent", level: 2 });
    expect(server.called("GET", /step=qbittorrent/).length).toBe(1);

    const answered = state("qbittorrent", [card("qbittorrent", [field("url", { label: "qBittorrent address", input: "url", value: "http://answered:8080" })])]);
    held.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Prowlarr connected." }, alert: null, completed: false, setup: answered } });
    await waitFor(() => expect((screen.getByLabelText("qBittorrent address") as HTMLInputElement).value).toBe("http://answered:8080"));
  });

  test("an older read that lands after a successful connection does not hide the libraries", async () => {
    const disconnected = state("audiobookshelf", [card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Audiobookshelf" })], {
      library_error: "Connection refused",
    });
    const connected = state("audiobookshelf", [
      card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "lib-audio", placeholder: "Not now" })], {
        phase: "libraries",
        title: "Libraries",
        submit: "Save and continue",
        libraries: [{ id: "lib-audio", name: "Audiobooks", media_type: "book" }],
      }),
      card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Change the Audiobookshelf connection", collapsed: true }),
    ]);
    const heldRead = deferred<{ body: unknown }>();
    const heldSave = deferred<{ body: unknown }>();
    let reads = 0;
    const server = setupServer()
      .on("GET", /\/admin\/setup\?step=audiobookshelf/, () => (++reads === 2 ? heldRead.promise : { body: disconnected }))
      .on("PUT", /\/admin\/setup\/steps\/audiobookshelf$/, () => heldSave.promise);
    const { services } = renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });
    await screen.findByText(/did not list libraries/);

    await userEvent.click(screen.getByRole("button", { name: "Test and continue" }));
    await waitFor(() => expect(server.called("PUT", /audiobookshelf$/).length).toBe(1));
    void services.queryClient.invalidateQueries();
    await waitFor(() => expect(reads).toBe(2));
    heldSave.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Audiobookshelf connected. Choose the libraries Shelfarr should scan." }, alert: null, completed: false, setup: connected } });
    expect(await screen.findByLabelText("Audiobook library")).toBeTruthy();

    heldRead.resolve({ body: disconnected });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.getByLabelText("Audiobook library")).toBeTruthy();
    expect(screen.queryByText(/did not list libraries/)).toBeNull();
  });

  test("a connection saved after moving away still shows its libraries on return", async () => {
    const connect = state("audiobookshelf", [card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Audiobookshelf" })]);
    const connected = state("audiobookshelf", [
      card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "", placeholder: "Not now" })], {
        phase: "libraries",
        title: "Libraries",
        submit: "Save and continue",
        libraries: [{ id: "lib-audio", name: "Audiobooks", media_type: "book" }],
      }),
    ]);
    const held = deferred<{ body: unknown }>();
    const server = setupServer({ audiobookshelf: connect, search: search() }).on("PUT", /\/admin\/setup\/steps\/audiobookshelf$/, () => held.promise);
    renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });
    await userEvent.click(await screen.findByRole("button", { name: "Test and continue" }));
    const steps = screen.getByRole("navigation", { name: "Setup steps" });
    await userEvent.click(within(steps).getByRole("link", { name: "Search" }));
    await screen.findByRole("heading", { name: "Search", level: 2 });
    await userEvent.click(within(screen.getByRole("navigation", { name: "Setup steps" })).getByRole("link", { name: "Audiobookshelf" }));
    await screen.findByRole("heading", { name: "Audiobookshelf", level: 3 });

    held.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Audiobookshelf connected." }, alert: null, completed: false, setup: connected } });
    expect(await screen.findByLabelText("Audiobook library")).toBeTruthy();
  });

  test("a restart that lands while the bare setup address is loading still shows the first step", async () => {
    const heldRestart = deferred<{ body: unknown }>();
    const heldRead = deferred<{ body: unknown }>();
    let bareReads = 0;
    const server = setupServer()
      .on("GET", /\/admin\/setup$/, () => (++bareReads === 1 ? heldRead.promise : { body: prowlarr() }))
      .on("GET", /\/api\/v1\/admin\/settings$/, () => ({
        body: { account: ACCOUNT, categories: [{ id: "system", title: "System", summary: "Health checks.", groups: [] }], notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "", redirect_uri: "", redirect_uri_acceptable: true } }, roles: [] },
      }))
      .on("POST", /\/admin\/setup\/restart$/, () => heldRestart.promise);
    const { router } = renderApp({ server, url: "/sub/preview/server/system" });
    await userEvent.click(await within(await waitFor(() => cardSection("Setup"))).findByRole("button", { name: "Run setup again" }));
    await waitFor(() => expect(server.called("POST", /restart$/).length).toBe(1));
    await router.navigate({ to: "/server/setup" });
    await waitFor(() => expect(bareReads).toBe(1));

    heldRestart.resolve({ body: { account: ACCOUNT, completed: false, setup: prowlarr() } });
    expect(await screen.findByRole("heading", { name: "Prowlarr", level: 2 })).toBeTruthy();
    expect(bareReads).toBe(2);
    heldRead.resolve({ body: prowlarr() });
  });

  test("returning to a step whose save is still pending shows what the save stored, and cannot resend the old form meanwhile", async () => {
    const heldSave = deferred<{ body: unknown }>();
    const heldReread = deferred<{ body: unknown }>();
    let saved = false;
    const server = setupServer({ qbittorrent: qbittorrent() })
      .on("GET", /\/admin\/setup\?step=prowlarr/, () => (saved ? heldReread.promise : { body: prowlarr() }))
      .on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => heldSave.promise);
    const { router } = renderApp({ server, url: "/sub/preview/server/setup?step=prowlarr" });
    const address = await screen.findByLabelText("Prowlarr address");
    await userEvent.clear(address);
    await userEvent.type(address, "http://new:9696");
    await userEvent.click(screen.getByRole("button", { name: "Test and continue" }));
    await waitFor(() => expect(server.called("PUT", /prowlarr$/).length).toBe(1));

    void router.navigate({ to: "/server/setup", search: { step: "qbittorrent" } });
    await userEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Leave and discard" }));
    await screen.findByRole("heading", { name: "qBittorrent", level: 2 });
    await router.navigate({ to: "/server/setup", search: { step: "prowlarr" } });
    await screen.findByRole("heading", { name: "Prowlarr", level: 2 });

    saved = true;
    heldSave.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Prowlarr connected." }, alert: null, completed: false, setup: qbittorrent() } });
    await waitFor(() => expect(server.called("GET", /step=prowlarr/).length).toBe(2));
    await waitFor(() => expect(screen.getByLabelText("Prowlarr address").closest("fieldset")!.disabled).toBe(true));
    expect((screen.getByRole("button", { name: "Skip setup" }) as HTMLButtonElement).disabled).toBe(true);

    heldReread.resolve({ body: state("prowlarr", [card("prowlarr", [field("url", { label: "Prowlarr address", input: "url", value: "http://new:9696" })])]) });
    await waitFor(() => expect((screen.getByLabelText("Prowlarr address") as HTMLInputElement).value).toBe("http://new:9696"));
    expect(screen.getByLabelText("Prowlarr address").closest("fieldset")!.disabled).toBe(false);
    expect(server.called("PUT", /prowlarr$/).length).toBe(1);
  });

  test("when the read after a save fails, the old form stays locked and offers Try again", async () => {
    const heldSave = deferred<{ body: unknown }>();
    let saved = false;
    let rereadWorks = false;
    const server = setupServer({ qbittorrent: qbittorrent() })
      .on("GET", /\/admin\/setup\?step=prowlarr/, () =>
        !saved ? { body: prowlarr() } : rereadWorks ? { body: state("prowlarr", [card("prowlarr", [field("url", { label: "Prowlarr address", input: "url", value: "http://new:9696" })])]) } : { status: 503, body: {} },
      )
      .on("PUT", /\/admin\/setup\/steps\/prowlarr$/, () => heldSave.promise);
    const { router } = renderApp({ server, url: "/sub/preview/server/setup?step=prowlarr" });
    const address = await screen.findByLabelText("Prowlarr address");
    await userEvent.clear(address);
    await userEvent.type(address, "http://new:9696");
    await userEvent.click(screen.getByRole("button", { name: "Test and continue" }));
    await waitFor(() => expect(server.called("PUT", /prowlarr$/).length).toBe(1));
    void router.navigate({ to: "/server/setup", search: { step: "qbittorrent" } });
    await userEvent.click(within(await screen.findByRole("dialog")).getByRole("button", { name: "Leave and discard" }));
    await screen.findByRole("heading", { name: "qBittorrent", level: 2 });
    await router.navigate({ to: "/server/setup", search: { step: "prowlarr" } });
    await screen.findByRole("heading", { name: "Prowlarr", level: 2 });

    saved = true;
    heldSave.resolve({ body: { account: ACCOUNT, outcome: { tone: "success", message: "Prowlarr connected." }, alert: null, completed: false, setup: qbittorrent() } });
    const problem = await screen.findByText(/latest state of this step could not be loaded/, {}, { timeout: 8000 });
    expect(screen.getByLabelText("Prowlarr address").closest("fieldset")!.disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Skip setup" }) as HTMLButtonElement).disabled).toBe(true);
    expect(server.called("PUT", /prowlarr$/).length).toBe(1);

    rereadWorks = true;
    await userEvent.click(within(problem.closest("p")!).getByRole("button", { name: "Try again" }));
    await waitFor(() => expect((screen.getByLabelText("Prowlarr address") as HTMLInputElement).value).toBe("http://new:9696"));
    expect(screen.getByLabelText("Prowlarr address").closest("fieldset")!.disabled).toBe(false);
    expect(screen.queryByText(/latest state of this step could not be loaded/)).toBeNull();
  }, 15_000);

  test("a confirmation left open is withdrawn when the step locks for a fresh read, and nothing is sent", async () => {
    const libraries = card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value: "old", placeholder: "Not now" })], {
      phase: "libraries",
      title: "Libraries",
      submit: "Save and continue",
      libraries: [
        { id: "old", name: "Old", media_type: "book" },
        { id: "new", name: "New", media_type: "book" },
      ],
    });
    const connection = card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Change the Audiobookshelf connection", collapsed: true });
    let failing = false;
    const server = setupServer().on("GET", /\/admin\/setup\?step=audiobookshelf/, () => (failing ? { status: 503, body: {} } : { body: state("audiobookshelf", [libraries, connection]) }));
    const { services } = renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });
    const change = await waitFor(() => cardSection("Change the Audiobookshelf connection") as HTMLDetailsElement);
    change.open = true;
    await userEvent.type(within(change).getByLabelText("Audiobookshelf address"), "/other");
    await userEvent.click(within(cardSection("Libraries")).getByRole("button", { name: "Save and continue" }));
    expect(await screen.findByRole("dialog", { name: "Leave without saving?" })).toBeTruthy();

    failing = true;
    void services.queryClient.invalidateQueries();
    const problem = await screen.findByText(/latest state of this step could not be loaded/, {}, { timeout: 8000 });
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(server.called("PUT", /audiobookshelf$/)).toEqual([]);

    failing = false;
    await userEvent.click(within(problem.closest("p")!).getByRole("button", { name: "Try again" }));
    expect(document.activeElement).toBe(screen.getByRole("heading", { name: "Audiobookshelf", level: 2 }));
    await waitFor(() => expect(within(cardSection("Libraries")).getByLabelText("Audiobook library").closest("fieldset")!.disabled).toBe(false));
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(server.called("PUT", /audiobookshelf$/)).toEqual([]);
  }, 15_000);

  test("a confirmation left open is withdrawn when the step's saved values change underneath it", async () => {
    const librariesWith = (value: string) =>
      card("audiobookshelf_libraries", [field("audiobook_library_id", { label: "Audiobook library", input: "library", value, placeholder: "Not now" })], {
        phase: "libraries",
        title: "Libraries",
        submit: "Save and continue",
        libraries: [
          { id: "old", name: "Old", media_type: "book" },
          { id: "new", name: "New", media_type: "book" },
        ],
      });
    const connection = card("audiobookshelf_connection", [field("url", { label: "Audiobookshelf address", input: "url", value: "http://abs:13378" })], { phase: "connection", title: "Change the Audiobookshelf connection", collapsed: true });
    let stored = "old";
    const server = setupServer().on("GET", /\/admin\/setup\?step=audiobookshelf/, () => ({ body: state("audiobookshelf", [librariesWith(stored), connection]) }));
    const { services } = renderApp({ server, url: "/sub/preview/server/setup?step=audiobookshelf" });
    const change = await waitFor(() => cardSection("Change the Audiobookshelf connection") as HTMLDetailsElement);
    change.open = true;
    await userEvent.type(within(change).getByLabelText("Audiobookshelf address"), "/other");
    await userEvent.click(within(cardSection("Libraries")).getByRole("button", { name: "Save and continue" }));
    expect(await screen.findByRole("dialog", { name: "Leave without saving?" })).toBeTruthy();

    stored = "new";
    await services.queryClient.invalidateQueries();
    await waitFor(() => expect((within(cardSection("Libraries")).getByLabelText("Audiobook library") as HTMLSelectElement).value).toBe("new"));
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(server.called("PUT", /audiobookshelf$/)).toEqual([]);
  });
});
