import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { Book, BookFormat, BookRequest, CatalogueAnswer } from "../src/contract";
import { bookRefreshInterval } from "../src/queries";
import { requestSteps } from "../src/components/BookPage";
import { ACCOUNT, detail, FakeServer, page, renderApp, session, standardServer, summary } from "./helpers";

afterEach(cleanup);

const BOOK_URL = "/sub/preview/books/openlibrary/OL900W";

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
  return { book_type: bookType, state: "requestable", note: null, publication: null, request: null, ...overrides };
}

function book(overrides: Partial<Book> = {}): Book {
  return {
    id: "openlibrary:OL900W",
    also: [],
    details: "catalogue",
    title: "Middlemarch",
    author: "George Eliot",
    year: 1871,
    description: "Lives and ambitions intersect in a provincial English town.",
    cover: { url: null, style: "moss" },
    source: { name: "Open Library", url: "https://openlibrary.org/works/OL900W" },
    formats: [format("ebook"), format("audiobook")],
    ...overrides,
  };
}

function bookServer(answer: Book | (() => Book), sessionOverrides: Parameters<typeof session>[0] = {}): FakeServer {
  return standardServer()
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session(sessionOverrides) }))
    .on("GET", /\/api\/v1\/books\/openlibrary\/OL900W/, () => ({ body: { account: ACCOUNT, book: typeof answer === "function" ? answer() : answer } }));
}

const ADMIN = { admin: { url: "/sub/admin" } };

const COPIES = [
  { id: "501", title: "Middlemarch (with illustrations)", format: "EPUB", size_bytes: 1_900_000, language: "English", source: "Project Gutenberg", state: "pending" as const, skipped: false, downloadable: true },
  { id: "502", title: "Middlemarch (text edition)", format: "EPUB", size_bytes: 900_000, language: "English", source: "Project Gutenberg", state: "pending" as const, skipped: false, downloadable: true },
];

describe("the Book page", () => {
  test("shows the work, a row per format, and a member's Request ebook that sends the work's links and the page's checks", async () => {
    let current = book();
    const server = bookServer(() => current).on("POST", /\/books\/openlibrary\/OL900W\/requests/, () => {
      current = book({ formats: [format("ebook", { state: "requested", request: request() }), format("audiobook")] });
      return { status: 201, body: { account: ACCOUNT, outcome: "created", book: current } };
    });
    renderApp({ server, url: `${BOOK_URL}?metadata=${"a".repeat(32)}&q=middlemarch` });
    expect(await screen.findByRole("heading", { level: 1, name: "Middlemarch" })).toBeTruthy();
    expect(screen.getByText("George Eliot", { selector: ".book-author-line" })).toBeTruthy();
    expect(screen.getByRole("link", { name: "Open Library (opens in a new tab)" }).getAttribute("href")).toBe("https://openlibrary.org/works/OL900W");
    expect(screen.getByRole("link", { name: /^Discover ?: results for “middlemarch”$/ }).getAttribute("href")).toBe("/sub/preview/discover?q=middlemarch");
    const card = screen.getByRole("region", { name: "On this server" });
    const rows = within(card).getAllByRole("listitem");
    expect(rows.map((row) => row.textContent)).toEqual(["EbookNot in libraryRequest ebook of Middlemarch", "AudiobookNot in library"]);
    expect(within(card).getByText("This preview requests ebooks only.")).toBeTruthy();

    await userEvent.click(within(card).getByRole("button", { name: "Request ebook of Middlemarch" }));
    expect(await within(card).findByText("Requested")).toBeTruthy();
    const [sent] = server.called("POST", /\/requests/);
    expect(sent?.path).toBe(`/sub/preview/api/v1/books/openlibrary/OL900W/requests?metadata=${"a".repeat(32)}`);
    expect(sent?.headers["x-csrf-token"]).toBe("token-123");
    expect(sent?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    const steps = screen.getByRole("region", { name: "Ebook request progress" });
    expect(within(steps).getAllByRole("listitem").map((item) => item.textContent)).toEqual(["✓Requested (done)", "Finding a copy", "Getting the file", "In library"]);
    expect(within(steps).getByText("Finding a copy").closest("li")?.getAttribute("aria-current")).toBe("step");
    expect(screen.getByRole("status", { name: "" }).textContent).toContain("Shelfarr will search for copies shortly.");
    expect(screen.queryByText(/approval/i)).toBeNull();
    expect(screen.queryByText("Choose a copy")).toBeNull();
  });

  test("follows the ordinary workflow by itself from finding a copy to getting the file to the reader", async () => {
    let current = book({ formats: [format("ebook", { state: "requested", request: request({ status: "searching", stage: "searching" }) }), format("audiobook")] });
    const { services } = renderApp({ server: bookServer(() => current), url: BOOK_URL });
    expect(await screen.findByText(/Looking for a suitable copy/)).toBeTruthy();
    expect(screen.queryByRole("radio")).toBeNull();
    current = book({ formats: [format("ebook", { state: "requested", request: request({ status: "downloading", stage: "downloading", download_percent: 42 }) }), format("audiobook")] });
    await act(() => services.queryClient.invalidateQueries());
    expect(await screen.findByText("Getting the file · 42%")).toBeTruthy();
    expect(within(screen.getByRole("region", { name: "Ebook request progress" })).getByText("Getting the file").closest("li")?.getAttribute("aria-current")).toBe("step");
    current = book({ details: "library", formats: [format("ebook", { state: "in_library", publication: summary({ reader_url: "/sub/read/7" }) }), format("audiobook")] });
    await act(() => services.queryClient.invalidateQueries());
    const card = await screen.findByRole("region", { name: "On this server" });
    const open = await within(card).findByRole("link", { name: "Start reading The Quiet Library in the reader" });
    expect(open.getAttribute("href")).toBe("/sub/read/7");
    expect(screen.queryByRole("region", { name: "Ebook request progress" })).toBeNull();
  });

  test("a request that stopped for attention says so instead of promising an automatic download", async () => {
    const ebook = format("ebook", { state: "requested", request: request({ status: "searching", stage: "searching", attention_needed: true }) });
    renderApp({ server: bookServer(book({ formats: [ebook, format("audiobook")] })), url: BOOK_URL });
    expect(await screen.findByText(/stopped working on this request until an administrator looks at it/)).toBeTruthy();
    expect(within(screen.getByRole("region", { name: "On this server" })).getByText("Needs attention")).toBeTruthy();
    expect(screen.queryByText(/Looking for a suitable copy/)).toBeNull();
    expect(bookRefreshInterval(book({ formats: [ebook] }))).toBe(60_000);
  });

  test("a request with nothing found yet stays on the page with its next search, not a new Request button", async () => {
    const ebook = format("ebook", { state: "requested", request: request({ status: "not_found", stage: "not_found", next_retry_at: new Date(Date.now() + 3 * 3600_000).toISOString() }) });
    renderApp({ server: bookServer(book({ formats: [ebook, format("audiobook")] })), url: BOOK_URL });
    const status = await screen.findByText(/No suitable copy has been found yet\./);
    expect(status.textContent).toBe("No suitable copy has been found yet. Shelfarr searches again in 3 hours.");
    expect(screen.queryByRole("button", { name: /Request ebook/ })).toBeNull();
  });

  test("a member whose copies were not picked automatically is told so, with no copy names or controls", async () => {
    const ebook = format("ebook", { state: "requested", request: request({ status: "searching", stage: "searching", choice_needed: true }) });
    renderApp({ server: bookServer(book({ formats: [ebook, format("audiobook")] })), url: BOOK_URL });
    expect(await screen.findByText(/none was picked automatically\. An administrator can choose one/)).toBeTruthy();
    expect(screen.getByRole("heading", { name: "Ebook request" })).toBeTruthy();
    expect(screen.queryByRole("radio")).toBeNull();
    expect(screen.queryByRole("button", { name: /Download this copy|Choose a copy|Search again/ })).toBeNull();
    expect(screen.getByRole("button", { name: "Cancel request" })).toBeTruthy();
  });

  test("an administrator chooses a stored copy from the table and the choice is sent for that request", async () => {
    const ebook = format("ebook", {
      state: "requested",
      request: request({ status: "searching", stage: "searching", choice_needed: true, own: false, requested_by: "Ada Reader", issue: null, copies: { selectable: true, can_search_again: true, candidates: COPIES } }),
    });
    const server = bookServer(book({ formats: [ebook, format("audiobook")] }), ADMIN).on("POST", /\/requests\/41\/selection$/, () => ({ body: { account: ACCOUNT, request: { id: "41", status: "downloading" } } }));
    renderApp({ server, url: BOOK_URL });
    const table = await screen.findByRole("table");
    expect(screen.getByRole("heading", { name: "Choose a copy" })).toBeTruthy();
    expect(screen.getByText("Requested by Ada Reader")).toBeTruthy();
    expect(within(table).getAllByRole("row").map((row) => row.textContent)).toEqual([
      "ChooseCopyFormatSizeLanguageSource",
      "Middlemarch (with illustrations)EPUB1.8 MBEnglishProject Gutenberg",
      "Middlemarch (text edition)EPUB879 KBEnglishProject Gutenberg",
    ]);
    const radios = within(table).getAllByRole("radio");
    expect(radios.map((radio) => (radio as HTMLInputElement).checked)).toEqual([true, false]);
    expect(within(screen.getByRole("region", { name: "Ebook request progress" })).getByText("Choose a copy").closest("li")?.getAttribute("aria-current")).toBe("step");

    await userEvent.click(screen.getByLabelText("Middlemarch (text edition)"));
    await userEvent.click(screen.getByRole("button", { name: "Download this copy" }));
    await waitFor(() => expect(server.called("POST", /selection$/)).toHaveLength(1));
    expect(server.called("POST", /selection$/)[0]?.body).toEqual({ result_id: "502" });
    expect(screen.getByRole("link", { name: "Add a link or file on the classic request page (opens the classic Shelfarr app)" }).getAttribute("href")).toBe("/sub/requests/41");
  });

  test("a copy that can no longer be chosen is disabled and an empty choice is announced and focuses the first choosable copy", async () => {
    const candidates = [{ ...COPIES[0]!, id: "500", title: "Gone copy", state: "rejected" as const, downloadable: false }, { ...COPIES[1]!, downloadable: true }];
    const ebook = format("ebook", { state: "requested", request: request({ status: "searching", stage: "searching", choice_needed: true, copies: { selectable: true, can_search_again: false, candidates } }) });
    const server = bookServer(book({ formats: [ebook, format("audiobook")] }), ADMIN);
    renderApp({ server, url: BOOK_URL });
    const [gone, usable] = (await screen.findAllByRole("radio")) as HTMLInputElement[];
    expect([gone?.disabled, usable?.disabled, usable?.checked]).toEqual([true, false, true]);
  });

  test("a refused choice says why and keeps the table", async () => {
    const ebook = format("ebook", { state: "requested", request: request({ status: "searching", stage: "searching", choice_needed: true, copies: { selectable: true, can_search_again: false, candidates: COPIES } }) });
    const server = bookServer(book({ formats: [ebook, format("audiobook")] }), ADMIN).on("POST", /selection$/, () => ({ status: 409, body: { error: "not_selectable", message: "Cannot replace a download while dispatch is in progress" } }));
    renderApp({ server, url: BOOK_URL });
    await userEvent.click(await screen.findByRole("button", { name: "Download this copy" }));
    expect((await screen.findByRole("alert")).textContent).toBe("Cannot replace a download while dispatch is in progress");
    expect(screen.getByRole("table")).toBeTruthy();
  });

  test("an ebook in the library opens in the existing reader at its place, and the audiobook row stays separate", async () => {
    const publication = summary({ id: "7", reading_status: "in_progress", progress: { asset_id: "a", position_seconds: null, fraction: 0.42, page: null, version: 3, observed_at: null, updated_at: "2026-11-22T10:00:00Z" }, reader_url: "/sub/read/7" });
    renderApp({ server: bookServer(book({ details: "library", formats: [format("ebook", { state: "in_library", publication }), format("audiobook")] })), url: BOOK_URL });
    const card = await screen.findByRole("region", { name: "On this server" });
    expect(within(card).getByText("In library")).toBeTruthy();
    expect(within(card).getByRole("link", { name: "Continue reading · 42% The Quiet Library in the reader" }).getAttribute("href")).toBe("/sub/read/7");
    expect(within(card).queryByRole("button")).toBeNull();
    expect(screen.queryByRole("region", { name: "Ebook request progress" })).toBeNull();
    expect(screen.getByRole("link", { name: "Reading status and files of The Quiet Library" }).getAttribute("href")).toBe("/sub/preview/library/7");
    expect(screen.getByText("Details from your library ·", { exact: false })).toBeTruthy();
  });

  test("an owned ebook whose file is gone says so instead of offering to read it", async () => {
    const publication = summary({ availability: "unavailable" });
    renderApp({ server: bookServer(book({ formats: [format("ebook", { state: "in_library", publication }), format("audiobook")] })), url: BOOK_URL });
    expect(await screen.findByText("In library, can't open here")).toBeTruthy();
    expect(screen.queryByRole("link", { name: /Start reading|Continue reading/ })).toBeNull();
    expect(screen.getByText(/no file this browser can open right now/)).toBeTruthy();
  });

  test("another account's request shows only that it exists", async () => {
    renderApp({ server: bookServer(book({ formats: [format("ebook", { state: "requested_by_someone" }), format("audiobook")] })), url: BOOK_URL });
    expect(await screen.findByText("Requested by someone here")).toBeTruthy();
    expect(screen.queryByRole("button")).toBeNull();
  });

  test("when the catalogue could not give details the page says so and does not offer a request it would refuse", async () => {
    const server = bookServer(book({ details: "missing", title: null, author: null, year: null, description: null }));
    renderApp({ server, url: BOOK_URL });
    expect(await screen.findByRole("heading", { level: 1, name: "Details not available" })).toBeTruthy();
    expect(screen.getByText(/could not be reached for this book's details/)).toBeTruthy();
    const button = screen.getByRole("button", { name: "Request ebook of this book" });
    expect(button.getAttribute("aria-disabled")).toBe("true");
    await userEvent.click(button);
    expect(server.called("POST", /requests/)).toEqual([]);
  });

  test("an unknown source is not a Book page and asks the server nothing", async () => {
    const server = bookServer(book());
    renderApp({ server, url: "/sub/preview/books/elsewhere/OL900W" });
    expect(await screen.findByRole("heading", { name: "That page is not part of this preview" })).toBeTruthy();
    expect(server.called("GET", /books/)).toEqual([]);
  });

  test("polls while the request moves and stops once nothing is changing", () => {
    const at = (overrides: Partial<BookRequest>) => book({ formats: [format("ebook", { state: "requested", request: request(overrides) }), format("audiobook")] });
    expect(bookRefreshInterval(book())).toBe(false);
    expect(bookRefreshInterval(at({ stage: "queued" }))).toBe(10_000);
    expect(bookRefreshInterval(at({ stage: "processing" }))).toBe(3_000);
    expect(bookRefreshInterval(at({ stage: "not_found" }))).toBe(false);
    expect(requestSteps(request({ stage: "processing" }))).toEqual({ steps: ["Requested", "Finding a copy", "Getting the file", "In library"], current: 3 });
  });
});

describe("Discover in the Rails preview", () => {
  const answer: CatalogueAnswer = {
    account: ACCOUNT,
    query: "middlemarch",
    providers: ["Open Library"],
    unavailable: [],
    items: [
      {
        book: { source: "openlibrary", id: "OL900W", metadata: "b".repeat(32) },
        title: "Middlemarch",
        author: "George Eliot",
        year: 1871,
        cover: { url: null, style: "moss" },
        source_name: "Open Library",
        formats: [
          { book_type: "ebook", state: "in_library" },
          { book_type: "audiobook", state: "requestable" },
        ],
      },
    ],
  };

  test("searches through Rails and links each result to its Book page with the work's links", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/discover\?/, () => ({ body: answer }));
    renderApp({ server, url: "/sub/preview/discover?q=middlemarch" });
    const link = await screen.findByRole("link", { name: "Middlemarch" });
    expect(link.getAttribute("href")).toBe(`/sub/preview/books/openlibrary/OL900W?q=middlemarch&metadata=${"b".repeat(32)}`);
    expect(server.called("GET", /discover/)[0]?.path).toBe("/sub/preview/api/v1/discover?q=middlemarch");
    expect(screen.getByRole("list", { name: "On this server" }).textContent).toBe("Ebook: in libraryAudiobook: not in library");
    expect(screen.getByRole("status").textContent).toBe("1 result for “middlemarch” from Open Library.");
    expect(screen.getByRole("link", { name: "Use the classic search (opens the classic Shelfarr app)" }).getAttribute("href")).toBe("/sub/search");
  });

  test("says when some catalogues could not be reached, so results may be incomplete", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/discover\?/, () => ({ body: { ...answer, providers: ["Hardcover", "Open Library"], unavailable: ["Hardcover"] } }));
    renderApp({ server, url: "/sub/preview/discover?q=middlemarch" });
    expect((await screen.findByRole("note")).textContent).toBe("Hardcover could not be reached, so these results may be incomplete. Try again in a moment.");
    expect(screen.getByRole("link", { name: "Middlemarch" })).toBeTruthy();
  });

  test("says when no catalogue is switched on", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/discover\?/, () => ({ body: { ...answer, providers: [], items: [] } }));
    renderApp({ server, url: "/sub/preview/discover?q=middlemarch" });
    expect(await screen.findByRole("heading", { name: "No catalogue is switched on" })).toBeTruthy();
  });

  test("an unreachable catalogue offers to try again", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/discover\?/, () => ({ status: 503, body: { error: "search_unavailable" } }));
    renderApp({ server, url: "/sub/preview/discover?q=middlemarch" });
    expect(await screen.findByRole("heading", { name: "The catalogue could not be reached" })).toBeTruthy();
  });
});

describe("the library detail", () => {
  test("links an owned book to its Book page through the book's own work links", async () => {
    const server = standardServer()
      .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail({ book_page: { source: "hardcover", id: "77" } }) } }))
      .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const link = await screen.findByRole("link", { name: "Formats and requests for this book" });
    expect(link.getAttribute("href")).toBe("/sub/preview/books/hardcover/77");
  });
});
