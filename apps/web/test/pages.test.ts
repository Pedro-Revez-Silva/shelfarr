import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { crc32 as zlibCrc32, deflateRawSync } from "node:zlib";
import { AccountGuard } from "../src/api/account-guard";
import { ApiError } from "../src/api/errors";
import type { ProgressPlace, ReaderAsset, ReaderPublication } from "../src/contract";
import { goReaderLink, goSummaryReaderLink } from "../src/reader/links";
import { guardedFetch, PageSession, pdfEngineLoader, type PageView } from "../src/reader/pages";
import { chosenAsset, firstOpening, remoteOpening } from "../src/reader/ReaderApp";
import { ACCOUNT, detail, summary } from "./helpers";

const ID = "c".repeat(64);
const ORDER = `/sub/preview/api/v1/library/9/assets/${ID}/reading_order`;
const MEDIA = `/sub/preview/api/v1/accounts/${ACCOUNT}/library/9/assets/${ID}`;
const NAMES = ["página 1.png", "página 2.png", "página 10.png", "日本/二.png"];
const encoder = new TextEncoder();

function png(width: number, height: number, seed: number): Uint8Array {
  const bytes = new Uint8Array(64).fill(seed);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  return bytes;
}

function href(name: Uint8Array): string {
  return [...name].map((byte) => (/[A-Za-z0-9\-._~/]/.test(String.fromCharCode(byte)) ? String.fromCharCode(byte) : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`)).join("");
}

function comic(options: { damage?: number } = {}) {
  const parts: Uint8Array[] = [];
  const items: Record<string, unknown>[] = [];
  let offset = 0;
  NAMES.forEach((text, index) => {
    const data = png(40, 60, index + 1);
    const name = encoder.encode(text);
    const compressed = new Uint8Array(deflateRawSync(data));
    const header = new Uint8Array(30);
    const view = new DataView(header.buffer);
    view.setUint32(0, 0x04034b50, true);
    view.setUint16(4, 20, true);
    view.setUint16(6, 0x0800, true);
    view.setUint16(8, 8, true);
    view.setUint32(14, zlibCrc32(data), true);
    view.setUint32(18, compressed.length, true);
    view.setUint32(22, data.length, true);
    view.setUint16(26, name.length, true);
    items.push({ position: index + 1, href: href(name), media_type: "image/png", size_bytes: data.length, compressed_size: compressed.length, compression_method: 8, local_header_offset: offset, crc32: options.damage === index + 1 ? "00000000" : zlibCrc32(data).toString(16).padStart(8, "0") });
    parts.push(header, name, compressed);
    offset += 30 + name.length + compressed.length;
  });
  const bytes = new Uint8Array(offset);
  let cursor = 0;
  for (const part of parts) {
    bytes.set(part, cursor);
    cursor += part.length;
  }
  const asset: ReaderAsset & { format: "cbz" } = { id: ID, filename: "Harbor.cbz", format: "cbz", media_type: "application/vnd.comicbook+zip", size_bytes: bytes.length, position: 0, url: MEDIA, page_count: items.length, reading_order_url: ORDER };
  return { bytes, items, asset };
}

type Seen = { url: string; headers: Headers; signal: AbortSignal | null | undefined };

function server(book: ReturnType<typeof comic>, options: { status?: number; error?: string; account?: string } = {}) {
  const seen: Seen[] = [];
  const gates: (() => void)[] = [];
  let holding = false;
  const fetcher = async (url: string, init: RequestInit): Promise<Response> => {
    const headers = new Headers(init.headers);
    seen.push({ url, headers, signal: init.signal });
    if (options.status) return new Response(JSON.stringify({ error: options.error }), { status: options.status, headers: { "Content-Type": "application/json" } });
    if (url === ORDER) return Response.json({ account: options.account ?? ACCOUNT, asset_id: ID, format: "cbz", items: book.items });
    if (holding) await new Promise<void>((resolve) => gates.push(resolve));
    const [, start, end] = /^bytes=(\d+)-(\d+)$/.exec(headers.get("Range") ?? "") ?? [];
    const first = Number(start);
    const last = Math.min(Number(end), book.bytes.length - 1);
    return new Response(book.bytes.slice(first, last + 1), { status: 206, headers: { ETag: `"${ID}"`, "Content-Range": `bytes ${first}-${last}/${book.bytes.length}` } });
  };
  return {
    seen,
    fetcher,
    hold: () => {
      holding = true;
    },
    release: () => {
      holding = false;
      for (const gate of gates.splice(0)) gate();
    },
  };
}

const settle = async (rounds = 30) => {
  for (let index = 0; index < rounds; index += 1) await new Promise((resolve) => setTimeout(resolve, 2));
};

function open(book: ReturnType<typeof comic>, fake: ReturnType<typeof server>) {
  const element = document.createElement("div");
  document.body.append(element);
  const guard = new AccountGuard(ACCOUNT);
  const moved: { place: ProgressPlace; at: number }[] = [];
  const failures: (string | null)[] = [];
  const checks: number[] = [];
  const views: PageView[] = [];
  let clock = Date.parse("2026-11-18T10:00:00.000Z");
  const session = new PageSession(
    element,
    book.asset,
    { resources: null, fetch: guardedFetch(guard, fake.fetcher), loadEngine: undefined },
    { view: (view) => views.push(view), moved: (place, at) => moved.push({ place, at }), failed: (message) => failures.push(message), unsure: () => checks.push(clock) },
    () => clock,
  );
  return { element, guard, session, moved, failures, checks, views, tick: (ms: number) => (clock += ms), now: () => clock };
}

const pageAt = (book: ReturnType<typeof comic>, position: number) => ({ href: book.items[position - 1]?.["href"], type: "image/png", locations: { position, totalProgression: (position - 1) / NAMES.length } });

const decode = HTMLImageElement.prototype.decode;
beforeEach(() => {
  HTMLImageElement.prototype.decode = () => Promise.resolve();
});
afterEach(() => {
  HTMLImageElement.prototype.decode = decode;
});

describe("the page reader session", () => {
  test("restoring a saved comic page shows it in reading order without recording anything", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    const opening = await opened.session.open(pageAt(book, 3) as never);
    expect(opening).toEqual({ count: 4, exact: true, position: 3 });
    expect(opened.moved).toEqual([]);
    expect(opened.views.at(-1)).toEqual({ position: 3, count: 4, zoom: 1, zoomed: false });
    expect(opened.element.querySelector("img")?.alt).toBe("Page 3 of 4");
    expect(fake.seen[0]?.url).toBe(ORDER);
    expect(fake.seen.every((call) => call.headers.get("X-Shelfarr-Account") === ACCOUNT)).toBe(true);
    expect(fake.seen.slice(1).every((call) => call.url === MEDIA && /^bytes=\d+-\d+$/.test(call.headers.get("Range") ?? "") && call.headers.get("If-Range") === `"${ID}"`)).toBe(true);
    opened.session.destroy();
  });

  test("each deliberate move is recorded once, when its page shows, dated by its own input", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    const input = opened.now();
    fake.hold();
    opened.session.go(3);
    opened.tick(5000);
    await settle(5);
    expect(opened.moved).toEqual([]);
    fake.release();
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 3) as never }, at: input }]);
    opened.session.go(3);
    await settle();
    expect(opened.moved).toHaveLength(1);
    opened.session.destroy();
  });

  test("rapid turns record only the page that finally shows, at the time of its own input", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    fake.hold();
    opened.session.next();
    opened.tick(200);
    const last = opened.now();
    opened.session.next();
    opened.tick(3000);
    fake.release();
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 3) as never }, at: last }]);
    opened.session.next();
    await settle();
    opened.session.next();
    await settle();
    expect(opened.moved.map((entry) => entry.place.locator?.locations?.position)).toEqual([3, 4]);
    opened.session.destroy();
  });

  test("zooming, fitting and showing another device's page are never reading and drop an unfinished move", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(pageAt(book, 2) as never);
    await opened.session.zoomIn();
    expect(opened.views.at(-1)?.zoomed).toBe(true);
    const stage = opened.element.querySelector<HTMLElement>(".consumer-pages__stage");
    expect([stage?.getAttribute("role"), stage?.tabIndex]).toEqual(["region", 0]);
    await opened.session.fitPage();
    expect([opened.views.at(-1)?.zoomed, stage?.hasAttribute("tabindex"), stage?.hasAttribute("role")]).toEqual([false, false, false]);
    fake.hold();
    opened.session.next();
    const remote = opened.session.showRemote(pageAt(book, 4) as never);
    fake.release();
    await remote;
    await settle();
    expect(opened.views.at(-1)?.position).toBe(4);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("adopting another device's place on the page a turn is still drawing drops that turn", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    fake.hold();
    opened.session.go(3);
    const remote = opened.session.showRemote(pageAt(book, 3) as never);
    fake.release();
    await remote;
    await settle();
    expect(opened.views.at(-1)?.position).toBe(3);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("an unchanged page box after adopting another device's page records nothing when the earlier turn finally draws", async () => {
    const book = comic();
    const opened = open(book, server(book));
    await opened.session.open(null);
    let releaseFirst = () => {};
    let decodes = 0;
    HTMLImageElement.prototype.decode = () => (decodes++ === 0 ? new Promise<void>((resolve) => (releaseFirst = resolve)) : Promise.resolve());
    opened.session.go(3);
    await settle();
    await opened.session.showRemote(pageAt(book, 3) as never);
    expect(opened.views.at(-1)?.position).toBe(3);
    opened.session.go(3);
    await settle();
    releaseFirst();
    await settle();
    expect(opened.views.at(-1)?.position).toBe(3);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("choosing another device's place in a file this page cannot show drops the turn still drawing", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    fake.hold();
    opened.session.go(3);
    opened.session.forgetTurns();
    fake.release();
    await settle();
    expect(opened.views.at(-1)?.position).toBe(3);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("a turn abandoned before its page showed asks for the session to be confirmed", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    expect(opened.checks).toEqual([]);
    fake.hold();
    opened.session.go(4);
    opened.session.go(1);
    fake.release();
    await settle();
    expect(opened.views.at(-1)?.position).toBe(1);
    expect(opened.checks.length).toBeGreaterThan(0);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("an extra turn past the end while the last page is still drawing keeps the turn that reached it", async () => {
    const book = comic();
    const opened = open(book, server(book));
    await opened.session.open(pageAt(book, 3) as never);
    let release = () => {};
    HTMLImageElement.prototype.decode = () => new Promise<void>((resolve) => (release = resolve));
    const turned = opened.now();
    opened.session.next();
    opened.tick(300);
    opened.session.next();
    await settle();
    release();
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 4) as never }, at: turned }]);
    opened.session.destroy();
  });

  test("a page that failed and is redrawn by zoom is recorded by the page box with the time of the turn that reached it; going back records nothing", async () => {
    const book = comic();
    const opened = open(book, server(book));
    await opened.session.open(null);
    let failing = true;
    HTMLImageElement.prototype.decode = () => (failing ? Promise.reject(new Error("decode")) : Promise.resolve());
    const turned = opened.now();
    opened.session.next();
    await settle();
    expect(opened.failures.filter(Boolean)).toEqual(["This page image couldn't be shown."]);
    failing = false;
    opened.tick(5000);
    await opened.session.zoomIn();
    opened.session.go(2);
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 2) as never }, at: turned }]);
    opened.session.previous();
    await settle();
    expect(opened.moved).toHaveLength(2);
    failing = true;
    opened.session.next();
    await settle();
    failing = false;
    opened.session.previous();
    await settle();
    expect(opened.moved.map((entry) => entry.place.locator?.locations?.position)).toEqual([2, 1]);
    opened.session.destroy();
  });

  test("retrying a failed page, or going to an unseen page after another device's place was chosen, is dated by that input", async () => {
    const book = comic();
    const opened = open(book, server(book));
    await opened.session.open(null);
    let failing = true;
    HTMLImageElement.prototype.decode = () => (failing ? Promise.reject(new Error("decode")) : Promise.resolve());
    opened.session.next();
    await settle();
    expect(opened.moved).toEqual([]);
    failing = false;
    opened.tick(9000);
    const retried = opened.now();
    opened.session.go(2);
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 2) as never }, at: retried }]);
    let release = () => {};
    HTMLImageElement.prototype.decode = () => new Promise<void>((resolve) => (release = resolve));
    opened.session.next();
    opened.session.forgetTurns();
    opened.tick(4000);
    const chosen = opened.now();
    HTMLImageElement.prototype.decode = () => Promise.resolve();
    opened.session.go(4);
    await settle();
    release();
    await settle();
    expect(opened.moved.slice(1)).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 4) as never }, at: chosen }]);
    opened.session.destroy();
  });

  test("a page drawn by zoom before its turn's own draw finishes is recorded with that turn's time, even if a failed turn follows", async () => {
    const book = comic({ damage: 3 });
    const opened = open(book, server(book));
    await opened.session.open(null);
    let decodes = 0;
    HTMLImageElement.prototype.decode = () => (decodes++ === 0 ? new Promise<void>(() => {}) : Promise.resolve());
    const turned = opened.now();
    opened.session.next();
    await settle();
    opened.tick(2000);
    await opened.session.zoomIn();
    await settle();
    expect(opened.moved).toEqual([{ place: { asset_id: ID, locator: pageAt(book, 2) as never }, at: turned }]);
    opened.session.next();
    await settle();
    expect(opened.failures.filter(Boolean)).toEqual(["This page is damaged: its checksum doesn't match."]);
    expect(opened.moved).toHaveLength(1);
    opened.session.destroy();
  });

  test("a pinch zoom made by the page itself is reported and makes the page a pannable region, without reading", async () => {
    const book = comic();
    const opened = open(book, server(book));
    await opened.session.open(null);
    const stage = opened.element.querySelector(".consumer-pages__stage") as HTMLElement;
    const pointer = (type: string, pointerId: number, x: number) => stage.dispatchEvent(new PointerEvent(type, { pointerId, clientX: x, clientY: 100, bubbles: true }));
    pointer("pointerdown", 1, 100);
    pointer("pointerdown", 2, 140);
    pointer("pointermove", 2, 220);
    pointer("pointerup", 1, 100);
    pointer("pointerup", 2, 220);
    await settle();
    expect(opened.views.at(-1)?.zoomed).toBe(true);
    expect([stage.getAttribute("role"), stage.tabIndex]).toEqual(["region", 0]);
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("a damaged page is refused with a message, is not recorded, and the next page clears the message", async () => {
    const book = comic({ damage: 2 });
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(null);
    opened.session.next();
    await settle();
    expect(opened.failures.filter(Boolean)).toEqual(["This page is damaged: its checksum doesn't match."]);
    expect(opened.element.querySelector(".consumer-page__unavailable")?.textContent).toBe("Page 2 couldn't be shown.");
    expect(opened.moved).toEqual([]);
    opened.session.next();
    await settle();
    expect(opened.failures.at(-1)).toBeNull();
    expect(opened.moved.map((entry) => entry.place.locator?.locations?.position)).toEqual([3]);
    opened.session.destroy();
  });

  test("keys turn pages unless an editing control or a zoomed page has them, and nothing turns past either end", async () => {
    const book = comic();
    const fake = server(book);
    const opened = open(book, fake);
    await opened.session.open(pageAt(book, 4) as never);
    const press = (target: EventTarget, key: string) => {
      const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
      Object.defineProperty(event, "target", { value: target });
      opened.session.key(event);
      return event.defaultPrevented;
    };
    expect(press(document.body, "ArrowRight")).toBe(true);
    await settle();
    expect(opened.moved).toEqual([]);
    const input = document.createElement("input");
    document.body.append(input);
    expect(press(input, "ArrowLeft")).toBe(false);
    await opened.session.zoomIn();
    const stage = opened.element.querySelector(".consumer-pages__stage") as HTMLElement;
    expect(press(stage, "ArrowLeft")).toBe(false);
    expect(press(document.body, "PageUp")).toBe(true);
    await settle();
    expect(opened.moved.map((entry) => entry.place.locator?.locations?.position)).toEqual([3]);
    opened.session.destroy();
  });
});

describe("page fetches", () => {
  test("carry the account, stay on this server and lock the guard when the session ends", async () => {
    const book = comic();
    const fake = server(book, { status: 401, error: "account_changed" });
    const guard = new AccountGuard(ACCOUNT);
    const fetcher = guardedFetch(guard, fake.fetcher);
    await expect(fetcher("https://evil.test/x", {})).rejects.toThrow("must come from this server");
    await expect(fetcher(MEDIA, { headers: { Range: "bytes=0-1" } })).rejects.toThrow("Sign in again");
    expect(fake.seen).toHaveLength(1);
    expect([fake.seen[0]?.url, fake.seen[0]?.headers.get("X-Shelfarr-Account"), fake.seen[0]?.headers.get("Range")]).toEqual([MEDIA, ACCOUNT, "bytes=0-1"]);
    expect(guard.getState()).toEqual({ status: "account_changed" });
    await expect(fetcher(MEDIA, {})).rejects.toBeInstanceOf(ApiError);
    expect(fake.seen).toHaveLength(1);
  });

  test("a reading order answered for another account locks the page and does not open, whatever its content type says", async () => {
    for (const type of ["application/json", "application/JSON; charset=utf-8", "text/plain"]) {
      const book = comic();
      const fake = server(book, { account: "99" });
      const typed = async (url: string, init: RequestInit) => {
        const answer = await fake.fetcher(url, init);
        return url === ORDER ? new Response(await answer.text(), { status: answer.status, headers: { "Content-Type": type } }) : answer;
      };
      const opened = open(book, { ...fake, fetcher: typed });
      await expect(opened.session.open(null)).rejects.toThrow("Sign in again");
      expect(opened.guard.getState()).toEqual({ status: "account_changed" });
      opened.session.destroy();
    }
  });

  test("a comic whose reading order is refused does not open", async () => {
    const book = comic();
    const opened = open(book, server(book, { status: 410, error: "asset_unavailable" }));
    await expect(opened.session.open(null)).rejects.toThrow("This comic changed or can't be read safely");
    expect(opened.moved).toEqual([]);
    opened.session.destroy();
  });

  test("the PDF renderer must come from this server and look like PDF.js", async () => {
    await expect(pdfEngineLoader("https://evil.test/pdf.js", async () => ({}))()).rejects.toThrow("must come from this server");
    await expect(pdfEngineLoader("/sub/preview/assets/pdf-engine.js", async () => ({ getDocument: () => null }))()).rejects.toThrow("not the expected one");
    await expect(pdfEngineLoader("/sub/preview/assets/pdf-engine.js", async () => Promise.reject(new Error("offline")))()).rejects.toThrow("could not be loaded");
    const imported: string[] = [];
    const engine = { getDocument: () => null, TextLayer: class {}, GlobalWorkerOptions: class {}, AnnotationMode: { ENABLE: 2 } };
    expect(
      await pdfEngineLoader("/sub/preview/assets/pdf-engine.js?x", async (address) => {
        imported.push(address);
        return engine;
      })(),
    ).toBe(engine);
    expect(imported).toEqual(["/sub/preview/assets/pdf-engine.js"]);
  });
});

describe("choosing what to open", () => {
  const asset = (id: string, format: string): ReaderAsset => ({ id, filename: `f.${format}`, format, media_type: "x", size_bytes: 1, position: 0, url: `/sub/preview/api/v1/accounts/12/library/7/assets/${id}` });
  const publication = (kind: "book" | "graphic", formats: string[], saved: string | null = null): ReaderPublication => ({
    id: "7",
    title: "T",
    author: null,
    book_type: "ebook",
    content_kind: kind,
    reading_status: "unread",
    assets: formats.map((format, index) => asset(String(index).repeat(64), format)),
    other_formats: [],
    progress: saved ? { asset_id: saved, locator: null, position_seconds: null, version: 1, observed_at: null, updated_at: "2026-11-18T10:00:00.000Z", client_mutation_id: "m" } : null,
  });

  test("the saved file wins; otherwise comics open as pages and books as text", () => {
    expect(chosenAsset(publication("graphic", ["epub", "pdf", "cbz"]))?.format).toBe("cbz");
    expect(chosenAsset(publication("graphic", ["epub", "pdf"]))?.format).toBe("pdf");
    expect(chosenAsset(publication("book", ["cbz", "pdf", "epub"]))?.format).toBe("epub");
    expect(chosenAsset(publication("book", ["cbz", "pdf"]))?.format).toBe("pdf");
    expect(chosenAsset(publication("book", ["epub", "pdf"], "1".repeat(64)))?.format).toBe("pdf");
    expect(chosenAsset(publication("book", ["epub"], "9".repeat(64)))?.format).toBe("epub");
    expect(chosenAsset(publication("book", []))).toBeNull();
  });

  test("another device's place opens in its own file when this reader lists it, and is reported when it does not", () => {
    const book = publication("book", ["epub", "pdf"], "1".repeat(64));
    const saved = book.progress;
    if (!saved) throw new Error("no saved place");
    expect(firstOpening(book)).toEqual({ asset: book.assets[1] ?? null, start: null, savedElsewhere: false });
    const elsewhere = publication("book", ["epub"], "f".repeat(64));
    expect(firstOpening(elsewhere)).toEqual({ asset: elsewhere.assets[0] ?? null, start: null, savedElsewhere: true });
    const pdfPlace = { ...saved, locator: { href: "document.pdf", type: "application/pdf", locations: { position: 4 } } };
    expect(remoteOpening(book, book.assets[1] ?? null, pdfPlace)).toEqual({ kind: "show" });
    expect(remoteOpening(book, book.assets[0] ?? null, pdfPlace)).toEqual({ kind: "open", opening: { asset: book.assets[1] ?? null, start: pdfPlace.locator, savedElsewhere: false } });
    expect(remoteOpening(book, book.assets[0] ?? null, { ...pdfPlace, asset_id: "e".repeat(64) })).toEqual({ kind: "unavailable" });
  });

  test("Details and Keep going link PDFs and comics to the reader only when this server can open them", () => {
    const pdf = detail({ format_label: "PDF", files: [{ id: ID, filename: "b.pdf", format: "pdf", media_type: "application/pdf", size_bytes: 1, position: 0, page_count: null }] });
    const all = ["cbz", "epub", "pdf"];
    expect(goReaderLink(pdf, "/sub/preview")).toBeNull();
    expect(goReaderLink(pdf, "/sub/preview", ["epub"])).toBeNull();
    expect(goReaderLink(pdf, "/sub/preview", all)).toBe("/sub/preview/library/7/read");
    for (const label of ["PDF", "Comic"]) {
      expect(goSummaryReaderLink(summary({ format_label: label }), "/sub/preview", ["epub"])).toBeNull();
      expect(goSummaryReaderLink(summary({ format_label: label }), "/sub/preview", all)).toBe("/sub/preview/library/7/read");
    }
    expect(goSummaryReaderLink(summary({ format_label: "Ebook" }), "/sub/preview", ["epub"])).toBe("/sub/preview/library/7/read");
    expect(goSummaryReaderLink(summary({ format_label: "Comic", availability: "unavailable" }), "/sub/preview", all)).toBeNull();
  });
});
