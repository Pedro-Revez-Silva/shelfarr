import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { Book, BookFormat, BookRequest, BookRequestResult, CatalogueAnswer, CatalogueItem, RequestOptions } from "../src/contract";
import { ACCOUNT, deferred, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const BOOK_URL = "/sub/preview/books/openlibrary/OL900W";
const HANDOFF = "b".repeat(32);
const LANGUAGES = [
  { code: "en", name: "English" },
  { code: "fr", name: "French" },
  { code: "de", name: "German" },
];

function options(overrides: Partial<RequestOptions> = {}): RequestOptions {
  return { formats: ["audiobook", "ebook"], default_format: "ebook", default_language: "en", languages: LANGUAGES, note_limit: 1000, ...overrides };
}

function request(overrides: Partial<BookRequest> = {}): BookRequest {
  return {
    id: "41",
    status: "pending",
    stage: "queued",
    attention_needed: false,
    download_percent: null,
    can_cancel: true,
    next_retry_at: null,
    created_at: "2026-11-22T10:00:00Z",
    updated_at: "2026-11-22T10:00:00Z",
    own: true,
    choice_needed: false,
    ...overrides,
  };
}

function format(bookType: BookFormat["book_type"], overrides: Partial<BookFormat> = {}): BookFormat {
  return { book_type: bookType, state: "requestable", publication: null, request: null, ...overrides };
}

function requested(bookType: BookFormat["book_type"], id: string): BookFormat {
  return format(bookType, { state: "requested", request: request({ id }) });
}

function book(formats: BookFormat[], requestOptions: RequestOptions = options()): Book {
  return {
    id: "openlibrary:OL900W",
    also: [],
    details: "catalogue",
    title: "Middlemarch",
    author: "George Eliot",
    year: 1871,
    description: null,
    cover: { url: null, style: "moss" },
    source: { name: "Open Library", url: null },
    formats,
    request_options: requestOptions,
  };
}

function outcome(answer: Book, results: BookRequestResult[]) {
  return { status: 201, body: { account: ACCOUNT, outcome: "created", results, book: answer } };
}

function bookServer(current: () => Book): FakeServer {
  return standardServer().on("GET", /\/api\/v1\/books\/openlibrary\/OL900W/, () => ({ body: { account: ACCOUNT, book: current() } }));
}

function card() {
  return screen.getByRole("region", { name: "On this server" });
}

describe("choosing what to request on the Book page", () => {
  test("the server's default format is accented, the other format is offered quietly, and a chosen language and note go with the press", async () => {
    let current = book([format("ebook"), format("audiobook")]);
    const answer = deferred<ReturnType<typeof outcome>>();
    const server = bookServer(() => current).on("POST", /\/requests/, () => answer.promise);
    renderApp({ server, url: BOOK_URL });
    const ebook = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook of Middlemarch" });
    const audiobook = within(card()).getByRole("button", { name: "Request audiobook of Middlemarch" });
    expect([ebook.className, audiobook.className]).toEqual(["button button--primary", "button"]);
    expect(within(card()).queryByRole("button", { name: /ebook and audiobook/ })).toBeNull();

    const user = userEvent.setup();
    await user.click(within(card()).getByText("Language and note"));
    const language = within(card()).getByLabelText("Language") as HTMLSelectElement;
    expect([...language.options].map((option) => [option.value, option.textContent])).toEqual([
      ["en", "English (server default)"],
      ["fr", "French"],
      ["de", "German"],
    ]);
    expect(language.value).toBe("en");
    await user.selectOptions(language, "de");
    const note = within(card()).getByLabelText("Note (optional)");
    expect(note.getAttribute("maxlength")).toBe("1000");
    await user.type(note, "  Unabridged, please. ");

    await user.click(audiobook);
    expect(audiobook.textContent).toBe("Requesting… of Middlemarch");
    expect([ebook.getAttribute("aria-disabled"), audiobook.getAttribute("aria-disabled")]).toEqual(["true", "true"]);
    await user.click(audiobook);
    await user.click(ebook);
    expect(server.called("POST", /\/requests/)).toHaveLength(1);
    expect(server.called("POST", /\/requests/)[0]?.body).toEqual({ book_type: "audiobook", language: "de", notes: "Unabridged, please." });

    current = book([format("ebook"), requested("audiobook", "52")]);
    await act(async () => answer.resolve(outcome(current, [{ book_type: "audiobook", outcome: "created" }])));
    const panel = await screen.findByRole("region", { name: "Audiobook request" });
    await waitFor(() => expect(document.activeElement).toBe(panel));
    expect(screen.getByRole("region", { name: "Audiobook request progress" })).toBeTruthy();
    expect(within(card()).getAllByRole("listitem").map((row) => row.textContent)).toEqual(["EbookNot in libraryRequest ebook of Middlemarch", "AudiobookRequested"]);
    expect((within(card()).getByLabelText("Note (optional)") as HTMLTextAreaElement).value).toBe("");
    expect((within(card()).getByLabelText("Language") as HTMLSelectElement).value).toBe("de");
  });

  test("a one-click default sends only the format, so the server's own default language applies", async () => {
    let current = book([format("ebook"), format("audiobook")], options({ languages: [LANGUAGES[0]!] }));
    const server = bookServer(() => current).on("POST", /\/requests/, () => {
      current = book([requested("ebook", "41"), format("audiobook")], current.request_options);
      return outcome(current, [{ book_type: "ebook", outcome: "created" }]);
    });
    renderApp({ server, url: `${BOOK_URL}?metadata=${HANDOFF}` });
    await userEvent.click(await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook of Middlemarch" }));
    expect(await screen.findByRole("region", { name: "Ebook request progress" })).toBeTruthy();
    const [sent] = server.called("POST", /\/requests/);
    expect([sent?.path, sent?.body, sent?.headers["x-csrf-token"], sent?.headers["x-shelfarr-account"]]).toEqual([
      `/sub/preview/api/v1/books/openlibrary/OL900W/requests?metadata=${HANDOFF}`,
      { book_type: "ebook" },
      "token-123",
      ACCOUNT,
    ]);
    expect(within(card()).queryByLabelText("Language")).toBeNull();
    expect(within(card()).getByText("Add a note")).toBeTruthy();
  });

  test("with a both default one accented action asks for the two formats, and a format the server refused says why", async () => {
    let current = book([format("ebook"), format("audiobook")], options({ default_format: "both" }));
    const server = bookServer(() => current).on("POST", /\/requests/, () => {
      current = book([format("ebook"), requested("audiobook", "52")], current.request_options);
      return outcome(current, [
        { book_type: "audiobook", outcome: "created" },
        { book_type: "ebook", outcome: "rejected", message: "Middlemarch Ebook: This ebook is blocked from being acquired again" },
      ]);
    });
    renderApp({ server, url: BOOK_URL });
    const both = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook and audiobook of Middlemarch" });
    expect(both.className).toBe("button button--primary");
    expect(within(card()).getByRole("button", { name: "Request ebook of Middlemarch" }).className).toBe("button");
    expect(within(card()).getByRole("button", { name: "Request audiobook of Middlemarch" }).className).toBe("button");
    await userEvent.click(both);
    expect((await within(card()).findByRole("alert")).textContent).toBe("The ebook was not requested: Middlemarch Ebook: This ebook is blocked from being acquired again");
    expect(server.called("POST", /\/requests/)[0]?.body).toEqual({ book_type: "both" });
    expect(within(card()).queryByRole("button", { name: /ebook and audiobook/ })).toBeNull();
    expect(within(card()).getByRole("button", { name: "Request ebook of Middlemarch" }).className).toBe("button button--primary");
  });

  test("with an ask default the formats sit side by side and neither is accented", async () => {
    renderApp({ server: bookServer(() => book([format("ebook"), format("audiobook")], options({ default_format: "ask" }))), url: BOOK_URL });
    const ebook = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook of Middlemarch" });
    expect([ebook.className, within(card()).getByRole("button", { name: "Request audiobook of Middlemarch" }).className]).toEqual(["button", "button"]);
    cleanup();
    renderApp({ server: bookServer(() => book([format("ebook", { state: "requested_by_someone" }), format("audiobook")])), url: BOOK_URL });
    const quiet = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request audiobook of Middlemarch" });
    expect(quiet.className).toBe("button");
  });

  test("only formats that can still be requested are offered, and nothing is offered when none can", async () => {
    let current = book([format("ebook", { state: "requested_by_someone" }), format("audiobook")], options({ default_format: "both" }));
    renderApp({ server: bookServer(() => current), url: BOOK_URL });
    const audiobook = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request audiobook of Middlemarch" });
    expect(audiobook.className).toBe("button button--primary");
    expect(within(card()).getAllByRole("button").map((button) => button.textContent)).toEqual(["Request audiobook of Middlemarch"]);
    expect(screen.getByRole("heading", { name: "Already requested" })).toBeTruthy();
    cleanup();
    current = book([requested("ebook", "41"), format("audiobook", { state: "requested_by_someone" })]);
    renderApp({ server: bookServer(() => current), url: BOOK_URL });
    expect(await screen.findByRole("heading", { name: "Audiobook already requested" })).toBeTruthy();
    expect(within(card()).queryAllByRole("button")).toEqual([]);
    expect(within(card()).queryByText("Language and note")).toBeNull();
  });

  test("a refused request stays on the pressed row with its reason and can be tried again", async () => {
    let refuse = true;
    let current = book([format("ebook"), format("audiobook")]);
    const server = bookServer(() => current).on("POST", /\/requests/, () => {
      if (refuse) return { status: 422, body: { error: "request_rejected", message: "Middlemarch Audiobook: Not today" } };
      current = book([format("ebook"), requested("audiobook", "52")]);
      return outcome(current, [{ book_type: "audiobook", outcome: "created" }]);
    });
    renderApp({ server, url: BOOK_URL });
    const audiobook = await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request audiobook of Middlemarch" });
    await userEvent.click(audiobook);
    const rows = within(card()).getAllByRole("listitem");
    expect((await within(rows[1]!).findByRole("alert")).textContent).toContain("Not today");
    expect(within(rows[0]!).queryByRole("alert")).toBeNull();
    expect(within(rows[1]!).getByRole("button").textContent).toBe("Try requesting again of Middlemarch");
    refuse = false;
    await userEvent.click(within(rows[1]!).getByRole("button"));
    expect(await screen.findByRole("region", { name: "Audiobook request progress" })).toBeTruthy();
    expect(server.called("POST", /\/requests/)).toHaveLength(2);
  });

  test("a different account answering the press locks the page and writes nothing from the answer", async () => {
    const server = bookServer(() => book([format("ebook"), format("audiobook")])).on("POST", /\/requests/, () => ({ status: 401, body: { error: "account_changed" } }));
    const { services } = renderApp({ server, url: BOOK_URL });
    await userEvent.click(await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook of Middlemarch" }));
    await waitFor(() => expect(services.guard.getState().status).toBe("account_changed"));
    await waitFor(() => expect(screen.queryByRole("region", { name: "On this server" })).toBeNull());
  });

  test("an answer that arrives after the session changed is not written to the page", async () => {
    const answer = deferred<ReturnType<typeof outcome>>();
    const server = bookServer(() => book([format("ebook"), format("audiobook")])).on("POST", /\/requests/, () => answer.promise);
    const { services } = renderApp({ server, url: BOOK_URL });
    await userEvent.click(await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook of Middlemarch" }));
    await act(async () => services.guard.lock("signed_out"));
    await act(async () => answer.resolve(outcome(book([requested("ebook", "41"), format("audiobook")]), [{ book_type: "ebook", outcome: "created" }])));
    expect(services.queryClient.getQueryData(services.keys.book("openlibrary", "OL900W", null))).toBeUndefined();
    expect(services.queryClient.getQueryCache().getAll()).toEqual([]);
  });
});

const ITEM: CatalogueItem = {
  book: { source: "openlibrary" as const, id: "OL900W", metadata: HANDOFF },
  title: "Middlemarch",
  author: "George Eliot",
  year: 1871,
  cover: { url: null, style: "moss" as const },
  source_name: "Open Library",
  formats: [
    { book_type: "ebook" as const, state: "requestable" as const },
    { book_type: "audiobook" as const, state: "requestable" as const },
  ],
};

function catalogue(requestOptions: RequestOptions | undefined, items: CatalogueItem[] = [ITEM]): CatalogueAnswer {
  return { account: ACCOUNT, query: "middlemarch", providers: ["Open Library"], unavailable: [], items, ...(requestOptions ? { request_options: requestOptions } : {}) };
}

function findServer(answer: CatalogueAnswer): FakeServer {
  return standardServer().on("GET", /\/api\/v1\/session$/, () => ({ body: session() })).on("GET", /\/api\/v1\/discover\?/, () => ({ body: answer }));
}

function liveFind(items: CatalogueItem[], requestOptions: RequestOptions = options()) {
  const shelf = new Map(items.map((item) => [`${item.book.source}:${item.book.id}`, item.formats]));
  const server = findServer(catalogue(requestOptions, items));
  server.on("GET", /\/api\/v1\/discover\?/, () => ({ body: catalogue(requestOptions, items.map((item) => ({ ...item, formats: shelf.get(`${item.book.source}:${item.book.id}`) ?? item.formats }))) }));
  const save = (key: string, formats: CatalogueItem["formats"]) => shelf.set(key, formats);
  return { server, save };
}

function states(ebook: BookFormat["state"], audiobook: BookFormat["state"]): CatalogueItem["formats"] {
  return [
    { book_type: "ebook", state: ebook },
    { book_type: "audiobook", state: audiobook },
  ];
}

describe("what a press sends and shows after the answer", () => {
  test("a Book page for a work with no book format offers no request", async () => {
    renderApp({ server: bookServer(() => book([format("ebook"), format("audiobook")], options({ formats: [] }))), url: BOOK_URL });
    expect(await screen.findByRole("heading", { level: 1, name: "Middlemarch" })).toBeTruthy();
    expect(within(card()).queryAllByRole("button")).toEqual([]);
    expect(within(card()).queryByText("Language and note")).toBeNull();
  });

  test("a new server default reaches a press made without opening the language choice", async () => {
    let defaultLanguage = "en";
    const server = findServer(catalogue(options())).on("POST", /\/requests/, () => outcome(book([requested("ebook", "41"), format("audiobook")]), [{ book_type: "ebook", outcome: "created" }]));
    server.on("GET", /\/api\/v1\/discover\?/, () => ({ body: catalogue(options({ default_language: defaultLanguage })) }));
    const { services } = renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    expect(await screen.findByRole("button", { name: "Request ebook of Middlemarch" })).toBeTruthy();
    defaultLanguage = "fr";
    await act(async () => services.queryClient.refetchQueries({ queryKey: services.keys.catalogueAll }));
    await waitFor(() => expect((screen.getByLabelText("Language") as HTMLSelectElement).value).toBe("fr"));
    await userEvent.click(screen.getByRole("button", { name: "Request ebook of Middlemarch" }));
    await screen.findByText("Ebook requested.", { exact: false });
    expect(server.called("POST", /\/requests/)[0]?.body).toEqual({ book_type: "ebook" });
  });

  test("a press the server did not confirm searches Find again so the row shows what was saved", async () => {
    let saved = false;
    const server = findServer(catalogue(options())).on("POST", /\/requests/, () => {
      saved = true;
      return { status: 500, body: { error: "server_error" } };
    });
    server.on("GET", /\/api\/v1\/discover\?/, () => ({ body: catalogue(options(), [{ ...ITEM, formats: [{ book_type: "ebook", state: saved ? "requested" : "requestable" }, ITEM.formats[1]!] }]) }));
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook of Middlemarch" }));
    expect((await screen.findByRole("alert")).textContent).toBe("The server did not confirm this. The page now shows the current state; try again only if nothing changed.");
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: not in library"));
    expect(server.called("GET", /discover\?/)).toHaveLength(2);
  });

  test("after a press Find searches again and shows what the server now has, including a format another tab cancelled", async () => {
    const { server, save } = liveFind([{ ...ITEM, formats: states("requested", "requestable") }], options({ default_format: "ask" }));
    server.on("POST", /\/requests/, () => {
      save("openlibrary:OL900W", states("requestable", "requested"));
      return outcome(book([format("ebook"), requested("audiobook", "52")]), [{ book_type: "audiobook", outcome: "created" }]);
    });
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request audiobook of Middlemarch" }));
    await screen.findByText("Audiobook requested.", { exact: false });
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: not in libraryAudiobook: requested"));
    expect(server.called("GET", /discover\?/)).toHaveLength(2);
    await waitFor(() => expect(screen.getByRole("button", { name: "Request ebook of Middlemarch" }).getAttribute("aria-disabled")).toBeNull());
  });

  test("a search still running when the press is answered is replaced by one made after it", async () => {
    const { server, save } = liveFind([ITEM]);
    const slowSearch = deferred<{ body: CatalogueAnswer }>();
    const answer = deferred<ReturnType<typeof outcome>>();
    server.on("POST", /\/requests/, () => answer.promise);
    const { services } = renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook of Middlemarch" }));
    server.on("GET", /\/api\/v1\/discover\?/, () => slowSearch.promise);
    void services.queryClient.refetchQueries({ queryKey: services.keys.catalogueAll });
    server.on("GET", /\/api\/v1\/discover\?/, () => ({ body: catalogue(options(), [{ ...ITEM, formats: states("requested", "requestable") }]) }));
    save("openlibrary:OL900W", states("requested", "requestable"));
    await act(async () => answer.resolve(outcome(book([requested("ebook", "41"), format("audiobook")]), [{ book_type: "ebook", outcome: "created" }])));
    await act(async () => slowSearch.resolve({ body: catalogue(options(), [ITEM]) }));
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: not in library"));
    expect(screen.queryByRole("button", { name: "Request ebook of Middlemarch" })).toBeNull();
  });

  test("an unconfirmed press keeps its message after the refresh removes the last action", async () => {
    let saved = false;
    const server = findServer(catalogue(options(), [{ ...ITEM, formats: [ITEM.formats[0]!, { book_type: "audiobook", state: "in_library" }] }])).on("POST", /\/requests/, () => {
      saved = true;
      return { status: 500, body: { error: "server_error" } };
    });
    server.on("GET", /\/api\/v1\/discover\?/, () => ({ body: catalogue(options(), [{ ...ITEM, formats: [{ book_type: "ebook", state: saved ? "requested" : "requestable" }, { book_type: "audiobook", state: "in_library" }] }]) }));
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook of Middlemarch" }));
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: in library"));
    expect(screen.queryByRole("button", { name: /^Request/ })).toBeNull();
    expect(screen.getByRole("alert").textContent).toBe("The server did not confirm this. The page now shows the current state; try again only if nothing changed.");
  });

  test("a combined press the server did not confirm says so on the Book page after it shows what was saved", async () => {
    let current = book([format("ebook"), format("audiobook")], options({ default_format: "both" }));
    const server = bookServer(() => current).on("POST", /\/requests/, () => {
      current = book([format("ebook"), requested("audiobook", "52")], current.request_options);
      return { status: 500, body: { error: "server_error" } };
    });
    renderApp({ server, url: BOOK_URL });
    await userEvent.click(await within(await screen.findByRole("region", { name: "On this server" })).findByRole("button", { name: "Request ebook and audiobook of Middlemarch" }));
    expect(await screen.findByRole("region", { name: "Audiobook request progress" })).toBeTruthy();
    expect(within(card()).queryByRole("button", { name: /ebook and audiobook/ })).toBeNull();
    expect(within(card()).getByRole("alert").textContent).toBe("The server did not confirm this. The page now shows the current state; try again only if nothing changed.");
    expect(within(card()).getByRole("button", { name: "Request ebook of Middlemarch" })).toBeTruthy();
  });

  test("a refused retry of the remaining format keeps the format already saved", async () => {
    const { server, save } = liveFind([ITEM], options({ default_format: "both" }));
    server.on("POST", /\/requests/, (sent) => {
      if ((sent.body as { book_type: string }).book_type === "audiobook") return { status: 422, body: { error: "request_rejected", message: "Middlemarch Audiobook: Not today" } };
      save("openlibrary:OL900W", states("requested", "requestable"));
      return outcome(book([requested("ebook", "41"), format("audiobook")]), [
        { book_type: "audiobook", outcome: "rejected", message: "Middlemarch Audiobook: Not today" },
        { book_type: "ebook", outcome: "created" },
      ]);
    });
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook and audiobook of Middlemarch" }));
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: not in library"));
    const retry = await screen.findByRole("button", { name: "Request audiobook of Middlemarch" });
    await waitFor(() => expect(retry.getAttribute("aria-disabled")).toBeNull());
    await userEvent.click(retry);
    expect((await screen.findByRole("alert")).textContent).toBe("Middlemarch Audiobook: Not today");
    await waitFor(() => expect(server.called("GET", /discover\?/)).toHaveLength(3));
    expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: not in library");
    expect(screen.queryByRole("button", { name: /ebook and audiobook/ })).toBeNull();
  });

  test("another result for the same work shows the saved request once Find searches again, and a note is not sent twice", async () => {
    const linked: CatalogueItem = { ...ITEM, book: { source: "google_books", id: "gb-77", metadata: null }, title: "Middlemarch (Google Books)" };
    const unrelated = { ...ITEM, book: { ...ITEM.book, id: "OL901W" }, title: "Persuasion" };
    const { server, save } = liveFind([ITEM, linked, unrelated], options({ default_format: "ask" }));
    server.on("POST", /OL900W\/requests/, (sent) => {
      const ebook = (sent.body as { book_type: string }).book_type === "ebook";
      const now = ebook ? states("requested", "requested") : states("requestable", "requested");
      save("openlibrary:OL900W", now);
      save("google_books:gb-77", now);
      return outcome({ ...book([ebook ? requested("ebook", "41") : format("ebook"), requested("audiobook", "52")]), also: ["google_books:gb-77"] }, [{ book_type: ebook ? "ebook" : "audiobook", outcome: "created" }]);
    });
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    const [first] = await screen.findAllByRole("article");
    const user = userEvent.setup();
    await user.click(within(first!).getByText("Language and note"));
    await user.type(within(first!).getByLabelText("Note (optional)"), "Unabridged narrator");
    await user.click(within(first!).getByRole("button", { name: "Request audiobook of Middlemarch" }));
    await within(first!).findByText("Audiobook requested.", { exact: false });
    const [, second, third] = screen.getAllByRole("article");
    await waitFor(() => expect(within(second!).getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: not in libraryAudiobook: requested"));
    expect(within(third!).getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: not in libraryAudiobook: not in library");
    expect((within(first!).getByLabelText("Note (optional)") as HTMLTextAreaElement).value).toBe("");
    const ebook = within(first!).getByRole("button", { name: "Request ebook of Middlemarch" });
    await waitFor(() => expect(ebook.getAttribute("aria-disabled")).toBeNull());
    await user.click(ebook);
    await waitFor(() => expect(server.called("POST", /OL900W\/requests/)).toHaveLength(2));
    expect(server.called("POST", /OL900W\/requests/).map((sent) => sent.body)).toEqual([{ book_type: "audiobook", notes: "Unabridged narrator" }, { book_type: "ebook" }]);
  });

  test("a format that reached the library meanwhile is called that, not requested", async () => {
    const shelved = book([format("ebook", { state: "in_library" }), format("audiobook")]);
    const { server, save } = liveFind([ITEM]);
    server.on("POST", /\/requests/, () => {
      save("openlibrary:OL900W", states("in_library", "requestable"));
      return { body: { account: ACCOUNT, outcome: "existing", results: [{ book_type: "ebook", outcome: "existing" }], book: shelved } };
    });
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook of Middlemarch" }));
    expect(await screen.findByText("Already in the library.", { exact: false })).toBeTruthy();
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: in libraryAudiobook: not in library"));
  });
});

describe("requesting from a Find result", () => {
  test("one quiet action requests the default format in place, and Find searches again to show it", async () => {
    const answer = deferred<ReturnType<typeof outcome>>();
    const { server, save } = liveFind([ITEM], options({ languages: [LANGUAGES[0]!] }));
    server.on("POST", /\/requests/, () => answer.promise);
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    const press = await screen.findByRole("button", { name: "Request ebook of Middlemarch" });
    expect(press.className).toBe("button");
    expect(screen.queryByRole("button", { name: /audiobook/ })).toBeNull();
    expect(screen.queryByText("Add a note")).toBeNull();
    const user = userEvent.setup();
    await user.click(press);
    await user.click(press);
    expect(press.getAttribute("aria-disabled")).toBe("true");
    expect(server.called("POST", /\/requests/)).toHaveLength(1);
    save("openlibrary:OL900W", states("requested", "requestable"));
    await act(async () => answer.resolve(outcome(book([requested("ebook", "41"), format("audiobook")]), [{ book_type: "ebook", outcome: "created" }])));
    const done = await screen.findByText("Ebook requested.", { exact: false });
    await waitFor(() => expect(document.activeElement).toBe(done));
    expect(within(done).getByRole("link", { name: /^Follow it on its page ?: Middlemarch$/ }).getAttribute("href")).toBe(`/sub/preview/books/openlibrary/OL900W?q=middlemarch&metadata=${HANDOFF}`);
    await waitFor(() => expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: requestedAudiobook: not in library"));
    expect(screen.getAllByRole("button", { name: /Request/ }).map((button) => [button.textContent, button.className])).toEqual([["Request audiobook of Middlemarch", "button"]]);
    const [sent] = server.called("POST", /\/requests/);
    expect([sent?.path, sent?.body]).toEqual([`/sub/preview/api/v1/books/openlibrary/OL900W/requests?metadata=${HANDOFF}`, { book_type: "ebook" }]);
    expect(server.called("GET", /discover\?/)).toHaveLength(2);
    await waitFor(() => expect(screen.getByRole("status").textContent).toBe("1 result for “middlemarch” from Open Library."));
  });

  test("an ask default offers both formats, and several languages put a language and note on the row", async () => {
    const server = findServer(catalogue(options({ default_format: "ask" }))).on("POST", /\/requests/, () =>
      outcome(book([format("ebook"), requested("audiobook", "52")]), [{ book_type: "audiobook", outcome: "created" }]),
    );
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    expect(await screen.findByRole("button", { name: "Request ebook of Middlemarch" })).toBeTruthy();
    const user = userEvent.setup();
    await user.click(screen.getByText("Language and note"));
    await user.selectOptions(screen.getByLabelText("Language"), "fr");
    await user.click(screen.getByRole("button", { name: "Request audiobook of Middlemarch" }));
    expect(await screen.findByText("Audiobook requested.", { exact: false })).toBeTruthy();
    expect(server.called("POST", /\/requests/)[0]?.body).toEqual({ book_type: "audiobook", language: "fr" });
    expect(screen.getByRole("button", { name: "Request ebook of Middlemarch" })).toBeTruthy();
  });

  test("a refused request is explained on its row only, and an older answer without options offers no request", async () => {
    const other = { ...ITEM, book: { ...ITEM.book, id: "OL901W" }, title: "Persuasion" };
    const server = findServer(catalogue(options(), [ITEM, other])).on("POST", /OL900W\/requests/, () => ({ status: 422, body: { error: "request_rejected", message: "Middlemarch Ebook: Not today" } }));
    renderApp({ server, url: "/sub/preview/find?q=middlemarch" });
    await userEvent.click(await screen.findByRole("button", { name: "Request ebook of Middlemarch" }));
    const [first, second] = screen.getAllByRole("article");
    expect((await within(first!).findByRole("alert")).textContent).toContain("Not today");
    expect(within(second!).queryByRole("alert")).toBeNull();
    expect(within(first!).getByRole("button", { name: "Try requesting again of Middlemarch" })).toBeTruthy();
    cleanup();
    renderApp({ server: findServer(catalogue(undefined)), url: "/sub/preview/find?q=middlemarch" });
    expect(await screen.findByRole("link", { name: "Middlemarch" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Request/ })).toBeNull();
  });
});
