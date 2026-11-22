import { describe, expect, test } from "bun:test";
import { createMemoryHistory } from "@tanstack/react-router";
import { render, screen, waitFor, within } from "@testing-library/react";
import { App } from "../src/App";
import { resetFirstPage } from "../src/components/PageHeading";
import { readerEnvelopeSchema, type Boot, type GoBoot, type PublicationDetail } from "../src/contract";
import { GoApp } from "../src/go/GoApp";
import { RailsOffline } from "../src/offline/RailsOffline";
import { publicationReaderHref, summaryReaderHref } from "../src/reader/links";
import { createAppRouter } from "../src/router";
import { createServices } from "../src/services";
import { signedIn, signedOut } from "./go-helpers";
import { ACCOUNT, FakeServer, MOUNT, boot, detail, page, session, summary } from "./helpers";
import { EPUB_ID, MemoryOfflineStore, savedBook } from "./offline-helpers";

const API = `${MOUNT}/api/v1`;
const OFFLINE = { worker: `${MOUNT}/offline-worker.js`, scope: `${MOUNT}/library/`, downloads: `${MOUNT}/library/downloads` };
const FORMATS = ["cbz", "epub", "pdf"];
const railsBoot: Boot = { ...boot, reader_formats: FORMATS, offline: OFFLINE };

function readerBoot(view: GoBoot["view"]): GoBoot {
  return { version: 1, runtime: "rails", view, mount: MOUNT, api: API, reader_formats: FORMATS, offline: OFFLINE, classic_downloads: "/sub/read/downloads", reader_engine: "/sub/assets/consumer_reader_engine-0123abcd.js" };
}

const track = { id: "a".repeat(64), filename: "Part 1.mp3", format: "mp3", media_type: "audio/mpeg", size_bytes: 10, position: 0, url: `${API}/accounts/${ACCOUNT}/library/8/assets/${"a".repeat(64)}` };

function readerServer(bootstrap: () => unknown, publication: object) {
  return new FakeServer()
    .on("GET", /\/auth\/bootstrap$/, () => ({ body: bootstrap() }))
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/library\/8\/reader$/, () => ({ body: { account: ACCOUNT, publication } }));
}

function renderReader(server: FakeServer, view: GoBoot["view"] = "reader", url = `${MOUNT}/library/8/read`, store = new MemoryOfflineStore()) {
  resetFirstPage();
  window.history.replaceState(null, "", url);
  return render(<GoApp boot={readerBoot(view)} fetcher={server.fetcher} store={store} />);
}

function renderRails(server: FakeServer, url: string, store = new MemoryOfflineStore(), appBoot: Boot = railsBoot) {
  resetFirstPage();
  const services = createServices({ boot: appBoot, csrfToken: () => "meta-token", fetcher: server.fetcher });
  const router = createAppRouter({ basepath: MOUNT, history: createMemoryHistory({ initialEntries: [url] }) });
  return render(
    <RailsOffline services={services} store={store} fetcher={server.fetcher}>
      <App services={services} router={router} />
    </RailsOffline>,
  );
}

function withWorker(): () => void {
  const targets: [object, string][] = [[window, "isSecureContext"], [globalThis, "isSecureContext"], [navigator, "serviceWorker"], [globalThis, "caches"], [globalThis, "indexedDB"]];
  const saved = targets.map(([target, key]) => Object.getOwnPropertyDescriptor(target, key));
  const registration = { scope: new URL(OFFLINE.scope, window.location.href).href, active: { scriptURL: new URL(OFFLINE.worker, window.location.href).href }, unregister: async () => true };
  const values = [true, true, { getRegistration: async () => registration, register: async () => registration }, { keys: async () => [] }, {}];
  targets.forEach(([target, key], index) => Object.defineProperty(target, key, { value: values[index], configurable: true }));
  return () =>
    targets.forEach(([target, key], index) => {
      const previous = saved[index];
      if (previous) Object.defineProperty(target, key, previous);
      else Reflect.deleteProperty(target, key);
    });
}

describe("the reader served by Rails", () => {
  test("opens the player from the Rails session, offers the narrating reader for read-along books and says audiobooks can't be saved here", async () => {
    const publication = { id: "8", title: "Spoken Sampler", author: null, book_type: "audiobook", content_kind: "book", reading_status: "unread", assets: [track], other_formats: [], progress: null, classic_reader: { url: "/sub/read/8", read_along: true } };
    const server = readerServer(() => ({ ...signedIn(), offline_expires_in: 3600 }), publication);
    renderReader(server);
    await screen.findByRole("heading", { level: 1, name: "Spoken Sampler" });
    expect(screen.getByRole("link", { name: "Open with read-along" }).getAttribute("href")).toBe("/sub/read/8");
    expect(screen.getByRole("link", { name: "Back to the book" }).getAttribute("href")).toBe(`${MOUNT}/library/8`);
    expect(screen.getByText("This book can't be saved here yet: this reader keeps EPUBs offline, not audiobooks.")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Download it in the web reader" }).getAttribute("href")).toBe("/sub/read/8");
    expect(server.called("GET", /\/library\/8\/reader$/)[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(server.called("PUT", /progress$/)).toEqual([]);
  });

  test("a book with several files points to the web reader to choose another, and a stored place with a null type is accepted", async () => {
    const first = { id: "c".repeat(64), filename: "First.epub", format: "epub", media_type: "application/epub+zip", size_bytes: 10, position: 0, url: `${API}/accounts/${ACCOUNT}/library/8/assets/${"c".repeat(64)}` };
    const second = { ...first, id: "d".repeat(64), filename: "Second.epub", position: 1, url: `${API}/accounts/${ACCOUNT}/library/8/assets/${"d".repeat(64)}` };
    const progress = { asset_id: second.id, locator: { href: "OEBPS/one.xhtml", type: null, locations: { progression: 0.25 } }, position_seconds: null, version: 2, observed_at: null, updated_at: "2026-11-22T10:00:00.000Z", client_mutation_id: "m" };
    const publication = { id: "8", title: "Two Files", author: null, book_type: "ebook", content_kind: "book", reading_status: "in_progress", assets: [first, second], other_formats: [], progress, classic_reader: { url: "/sub/read/8", read_along: false } };
    expect(readerEnvelopeSchema.safeParse({ account: ACCOUNT, publication }).success).toBe(true);
    const server = readerServer(() => ({ ...signedIn(), offline_expires_in: 3600 }), publication);
    renderReader(server);
    expect((await screen.findByRole("link", { name: "Choose a file" })).getAttribute("href")).toBe("/sub/read/8");
    expect(screen.getByText("This book has 2 files and this reader opens one. To read another, choose it in the web reader.")).toBeTruthy();
    expect(screen.queryByRole("combobox", { name: "File" })).toBeNull();
    expect(server.called("PUT", /progress$/)).toEqual([]);
  });

  test("a book without read-along shows no narration offer", async () => {
    const publication = { id: "8", title: "Plain Sampler", author: null, book_type: "audiobook", content_kind: "book", reading_status: "unread", assets: [track], other_formats: [], progress: null, classic_reader: { url: "/sub/read/8", read_along: false } };
    renderReader(readerServer(() => ({ ...signedIn(), offline_expires_in: 3600 }), publication));
    await screen.findByRole("heading", { level: 1, name: "Plain Sampler" });
    expect(screen.queryByRole("link", { name: "Open with read-along" })).toBeNull();
  });

  test("a session that ended sends the reader to Rails' own sign-in instead of a password form", async () => {
    const server = readerServer(() => ({ ...signedOut(), sign_in: { available: false, reason: "rails_sign_in" } }), {});
    renderReader(server);
    const link = await screen.findByRole("link", { name: "Sign in to Shelfarr" });
    expect(link.getAttribute("href")).toBe(window.location.href);
    expect(screen.queryByLabelText("Username")).toBeNull();
    expect(server.called("POST", /\/auth\/login$/)).toEqual([]);
  });

  test("Downloads points to the downloads kept by the web reader without touching them", async () => {
    const store = new MemoryOfflineStore();
    store.record = { account: ACCOUNT, confirmedAt: Date.now(), validForMs: 3_600_000 };
    renderReader(readerServer(() => ({ ...signedIn(), offline_expires_in: 3600 }), {}), "downloads", `${MOUNT}/library/downloads`, store);
    const section = (await screen.findByRole("heading", { name: "Saved in the web reader" })).closest("section") as HTMLElement;
    expect(within(section).getByRole("link", { name: "Open those downloads" }).getAttribute("href")).toBe("/sub/read/downloads");
  });

  test("offline, Downloads still points to the web reader's own downloads", async () => {
    const store = new MemoryOfflineStore();
    store.record = { account: ACCOUNT, confirmedAt: Date.now(), validForMs: 3_600_000 };
    const unreachable = new FakeServer().on("GET", /\/auth\/bootstrap$/, () => {
      throw new TypeError("Failed to fetch");
    });
    renderReader(unreachable, "downloads", `${MOUNT}/library/downloads`, store);
    await screen.findByText(/You're offline\./);
    const section = screen.getByRole("heading", { name: "Saved in the web reader" }).closest("section") as HTMLElement;
    expect(within(section).getByRole("link", { name: "Open those downloads" }).getAttribute("href")).toBe("/sub/read/downloads");
  });
});

describe("the Go runtime keeps its offline controls", () => {
  test("an audiobook's Go player and details offer no Rails download fallback", async () => {
    const publication = { id: "8", title: "Go Sampler", author: null, book_type: "audiobook", content_kind: "book", reading_status: "unread", assets: [track], other_formats: [], progress: null };
    const server = readerServer(() => ({ ...signedIn(), offline_expires_in: 3600 }), publication);
    resetFirstPage();
    window.history.replaceState(null, "", "/preview/library/8/read");
    render(<GoApp boot={{ version: 1, runtime: "go", view: "reader", mount: "/preview", api: "/preview/api/v1", offline: { worker: "/preview/offline-worker.js", scope: "/preview/library/", downloads: "/preview/library/downloads" }, reader_engine: "/preview/assets/reader-engine.0123456789abcdef.js" }} fetcher={server.fetcher} store={new MemoryOfflineStore()} />);
    await screen.findByRole("heading", { level: 1, name: "Go Sampler" });
    expect(screen.queryByText(/can't be saved here yet/)).toBeNull();
    expect(screen.queryByRole("link", { name: "Download it in the web reader" })).toBeNull();
  });
});

describe("reader links in the Rails library", () => {
  const services = (formats: readonly string[] | undefined) => ({ mode: "rails" as const, boot: { mount: MOUNT, ...(formats ? { reader_formats: formats } : {}) } });

  test("open the TypeScript reader for every format the server's reader opens, and keep the web reader address otherwise", () => {
    const epub = detail();
    const comic: PublicationDetail = detail({ format_label: "Comic", content_kind: "graphic", files: [{ ...detail().files[0]!, format: "cbz" }] });
    const audio = summary({ id: "8", action: "listen", book_type: "audiobook", format_label: "Audiobook", reader_url: "/sub/read/8" });
    expect(publicationReaderHref(epub, services(FORMATS))).toBe(`${MOUNT}/library/7/read`);
    expect(publicationReaderHref(comic, services(FORMATS))).toBe(`${MOUNT}/library/7/read`);
    expect(summaryReaderHref(audio, services(FORMATS))).toBe(`${MOUNT}/library/8/read`);
    expect(summaryReaderHref(summary({ format_label: "Mystery" }), services(FORMATS))).toBe("/sub/read/7");
    expect(publicationReaderHref(epub, services(undefined))).toBe("/sub/read/7");
    expect(summaryReaderHref(audio, services(undefined))).toBe("/sub/read/8");
    expect(publicationReaderHref(detail({ availability: "unavailable", files: [] }), services(FORMATS))).toBe("/sub/read/7");
  });
});

describe("offline copies from the Rails library", () => {
  function libraryServer(bootstrap: () => unknown) {
    return new FakeServer()
      .on("GET", /\/auth\/bootstrap$/, () => ({ body: bootstrap() }))
      .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
      .on("GET", /\/api\/v1\/continue/, () => ({ body: { account: ACCOUNT, items: [] } }))
      .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
      .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail() } }))
      .on("GET", /\/api\/v1\/library\/9$/, () => ({ body: { account: ACCOUNT, publication: detail({ id: "9", format_label: "PDF", reader_url: "/sub/read/9", files: [{ ...detail().files[0]!, format: "pdf" }] }) } }))
      .on("PUT", /\/api\/v1\/library\/7\/progress$/, (request) => ({
        body: { account: ACCOUNT, progress: { ...(request.body as object), position_seconds: null, version: 1, updated_at: "2026-11-22T12:00:00.000Z" } },
      }));
  }

  test("an EPUB's details open the TypeScript reader and offer saving once Rails confirms the account", async () => {
    renderRails(libraryServer(() => ({ ...signedIn(), offline_expires_in: 3600 })), `${MOUNT}/library/7`);
    const section = (await screen.findByRole("heading", { name: "Offline reading" })).closest("section") as HTMLElement;
    expect(within(section).getByRole("button", { name: "Save for offline reading" })).toBeTruthy();
    expect(screen.getByRole("link", { name: /Start reading/ }).getAttribute("href")).toBe(`${MOUNT}/library/7/read`);
  });

  test("a PDF's details say it can't be saved here and point to the reader that downloads it", async () => {
    renderRails(libraryServer(() => ({ ...signedIn(), offline_expires_in: 3600 })), `${MOUNT}/library/9`);
    expect(await screen.findByText("This book can't be saved here yet: this reader keeps EPUBs offline, not PDFs.")).toBeTruthy();
    expect(screen.getByRole("link", { name: "Download it in the web reader" }).getAttribute("href")).toBe("/sub/read/9");
    expect(screen.getByRole("link", { name: /Start reading/ }).getAttribute("href")).toBe(`${MOUNT}/library/9/read`);
  });

  test("nothing offline is offered when the bootstrap names another account or nobody", async () => {
    for (const answer of [{ ...signedIn("4"), offline_expires_in: 3600 }, signedOut()]) {
      const view = renderRails(libraryServer(() => answer), `${MOUNT}/library/7`);
      await screen.findByRole("heading", { name: detail().title });
      await new Promise((resolve) => setTimeout(resolve, 30));
      expect(screen.queryByRole("heading", { name: "Offline reading" })).toBeNull();
      view.unmount();
    }
  });

  test("a place reached offline is sent when the Rails library opens, with the bootstrap's token and its own activity time", async () => {
    const observedAt = "2026-11-20T11:00:00.000Z";
    const locator = { href: "OEBPS/two.xhtml", type: "application/xhtml+xml", locations: { progression: 0.5, totalProgression: 0.75 } };
    const store = new MemoryOfflineStore();
    store.record = { account: ACCOUNT, confirmedAt: Date.now(), validForMs: 3_600_000 };
    store.saved.set(`${ACCOUNT}|7`, savedBook({ key: `${ACCOUNT}|7`, account: ACCOUNT, devicePlace: { asset_id: EPUB_ID, locator, observedAt, recordedAt: Date.now() - 1000, upload: { state: "pending", request: null, rebases: 0 } } }));
    const server = libraryServer(() => ({ ...signedIn(ACCOUNT, "rails-form-token"), offline_expires_in: 3600 }));
    const restore = withWorker();
    try {
      renderRails(server, `${MOUNT}/library`, store);
      await waitFor(() => expect(server.called("PUT", /progress$/)).toHaveLength(1));
      const sent = server.called("PUT", /progress$/)[0]!;
      expect(sent.path).toBe(`${API}/library/7/progress`);
      expect(sent.body).toEqual({ asset_id: EPUB_ID, locator, observed_at: observedAt, expected_version: 0, client_mutation_id: expect.any(String) });
      expect([sent.headers["x-csrf-token"], sent.headers["x-shelfarr-account"]]).toEqual(["rails-form-token", ACCOUNT]);
      await waitFor(() => expect(store.saved.get(`${ACCOUNT}|7`)?.devicePlace?.upload).toEqual({ state: "synced", version: 1 }));
    } finally {
      restore();
    }
  });

  test("a Rails library without the reader keeps the web reader links and asks nothing about offline", async () => {
    const server = libraryServer(() => ({ ...signedIn(), offline_expires_in: 3600 }));
    renderRails(server, `${MOUNT}/library/7`, new MemoryOfflineStore(), boot);
    expect((await screen.findByRole("link", { name: /Start reading/ })).getAttribute("href")).toBe("/sub/read/7");
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(server.called("GET", /\/auth\/bootstrap$/)).toEqual([]);
    expect(screen.queryByRole("heading", { name: "Offline reading" })).toBeNull();
  });
});
