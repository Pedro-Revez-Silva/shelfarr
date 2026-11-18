import { describe, expect, test } from "bun:test";
import { AccountGuard } from "../src/api/account-guard";
import { ApiClient, type ProgressAnswer } from "../src/api/client";
import { ApiError } from "../src/api/errors";
import type { ProgressRequest, StoredProgress } from "../src/contract";
import { AudioSession } from "../src/reader/audio";
import { loadEngine } from "../src/reader/engine";
import { pageKey, playKey } from "../src/reader/keys";
import { goReaderLink, goSummaryReaderLink } from "../src/reader/links";
import { ProgressSession, type SaveState } from "../src/reader/progress";
import { readerPublicationId } from "../src/reader/ReaderApp";
import { ACCOUNT, boot, deferred, detail, FakeServer, summary } from "./helpers";

const ASSET = "a".repeat(64);
const OTHER = "b".repeat(64);
const NOW = Date.parse("2026-11-15T12:00:00.000Z");
const place = (progression: number) => ({ asset_id: ASSET, locator: { href: "OEBPS/one.xhtml", type: "application/xhtml+xml", locations: { progression, cfi: `epubcfi(/6/2!/4/${progression})` } } });

function stored(overrides: Partial<StoredProgress> = {}): StoredProgress {
  return { asset_id: ASSET, locator: place(0.1).locator, position_seconds: null, version: 1, observed_at: "2026-11-15T11:00:00.000Z", updated_at: "2026-11-15T11:00:01.000Z", client_mutation_id: "server-1", ...overrides };
}

type Call = { body: ProgressRequest; keepalive: boolean };

function harness(answers: ((body: ProgressRequest) => Promise<ProgressAnswer>)[], saved: StoredProgress | null = null) {
  const guard = new AccountGuard(ACCOUNT);
  const calls: Call[] = [];
  let clock = NOW;
  let id = 0;
  const session = new ProgressSession({
    write: (body, options) => {
      calls.push({ body, keepalive: options.keepalive });
      const next = answers.shift();
      if (!next) throw new Error("unexpected write");
      return next(body);
    },
    guard,
    assets: new Set([ASSET]),
    saved,
    now: () => clock,
    uuid: () => `mutation-${++id}`,
    delayMs: 5,
  });
  const states: SaveState["kind"][] = [];
  session.subscribe(() => states.push(session.getState().kind));
  return { guard, calls, session, states, tick: (ms: number) => (clock += ms) };
}

const savedAnswer = (version: number) => async (body: ProgressRequest): Promise<ProgressAnswer> => ({ kind: "saved", progress: stored({ ...body, locator: body.locator ?? null, version, client_mutation_id: body.client_mutation_id, observed_at: body.observed_at }) });
const settle = () => new Promise((resolve) => setTimeout(resolve, 25));

describe("saving a reading place", () => {
  test("a deliberate move is sent once, after a short wait, with the time of the move and the known version", async () => {
    const { calls, session, states, tick } = harness([savedAnswer(4)], stored({ version: 3 }));
    session.record(place(0.2));
    tick(1000);
    session.record(place(0.3));
    tick(700);
    await settle();
    expect(calls).toEqual([{ body: { ...place(0.3), observed_at: "2026-11-15T12:00:01.000Z", expected_version: 3, client_mutation_id: "mutation-1" }, keepalive: false }]);
    expect(states).toEqual(["saving", "saved"]);
  });

  test("an uncertain answer is never resent by itself; Retry sends the identical request and later places follow it", async () => {
    const failure = async (): Promise<ProgressAnswer> => {
      throw new ApiError("network", "lost");
    };
    const { calls, session, tick } = harness([failure, savedAnswer(1), savedAnswer(2)]);
    session.record(place(0.2));
    await settle();
    expect(session.getState().kind).toBe("uncertain");
    tick(5000);
    session.record(place(0.4));
    await settle();
    expect(calls).toHaveLength(1);
    session.retry();
    await settle();
    await settle();
    expect(calls[1]?.body).toEqual(calls[0]?.body as ProgressRequest);
    expect(calls[2]?.body).toEqual({ ...place(0.4), observed_at: "2026-11-15T12:00:05.000Z", expected_version: 1, client_mutation_id: "mutation-2" });
    expect(session.getState().kind).toBe("saved");
  });

  test("a refused token waits for Retry and resends the same mutation; a rejected place is reported and dropped", async () => {
    const csrf = async (): Promise<ProgressAnswer> => {
      throw new ApiError("csrf", "refused");
    };
    const invalid = async (): Promise<ProgressAnswer> => {
      throw new ApiError("invalid", "This asset is no longer available; refresh the publication");
    };
    const { calls, session } = harness([csrf, savedAnswer(1), invalid]);
    session.record(place(0.2));
    await settle();
    expect(session.getState().kind).toBe("token_refused");
    session.retry();
    await settle();
    expect(calls[1]?.body).toEqual(calls[0]?.body as ProgressRequest);
    session.record(place(0.3));
    await settle();
    expect(session.getState()).toEqual({ kind: "rejected", message: "This asset is no longer available; refresh the publication" });
    expect(calls).toHaveLength(3);
  });

  test("a later remote place is offered instead of overwritten, an earlier one is rebased and an undated one waits for a choice", async () => {
    const later = stored({ version: 5, observed_at: "2026-11-15T12:01:00.000Z", locator: place(0.9).locator });
    const earlier = stored({ version: 6, observed_at: "2026-11-15T11:59:00.000Z" });
    const undated = stored({ version: 8, observed_at: null });
    const conflict = (remote: StoredProgress) => async (): Promise<ProgressAnswer> => ({ kind: "conflict", progress: remote });
    const { calls, session } = harness([conflict(later), conflict(earlier), savedAnswer(7), conflict(undated), savedAnswer(9)], stored({ version: 4 }));
    session.record(place(0.2));
    await settle();
    expect(session.getState()).toEqual({ kind: "remote", remote: later });
    expect(calls).toHaveLength(1);
    expect(session.useRemote()).toEqual(later);
    session.record(place(0.3));
    await settle();
    await settle();
    expect(calls.map((call) => [call.body.expected_version, call.body.client_mutation_id, call.body.observed_at])).toEqual([
      [4, "mutation-1", "2026-11-15T12:00:00.000Z"],
      [5, "mutation-2", "2026-11-15T12:00:00.001Z"],
      [6, "mutation-3", "2026-11-15T12:00:00.001Z"],
    ]);
    session.record(place(0.5));
    await settle();
    expect(session.getState()).toEqual({ kind: "conflict", remote: undated, local: place(0.5) });
    session.keepLocal();
    await settle();
    expect(calls[4]?.body).toEqual({ ...place(0.5), observed_at: "2026-11-15T12:00:00.003Z", expected_version: 8, client_mutation_id: "mutation-5", resolve_conflict: true });
    expect(session.getState().kind).toBe("saved");
  });

  test("nothing is recorded or sent once the account guard locks or the session stops, even when an answer arrives late", async () => {
    const gate = deferred<ProgressAnswer>();
    const { calls, guard, session } = harness([() => gate.promise]);
    session.record(place(0.2));
    await settle();
    guard.lock("account_changed");
    gate.resolve({ kind: "saved", progress: stored({ version: 9 }) });
    await settle();
    session.record(place(0.3));
    session.flush();
    await settle();
    expect(calls).toHaveLength(1);
    expect(session.getState().kind).not.toBe("saved");
  });
});

describe("the progress contract", () => {
  test("a 409 answer is a conflict even though its body also carries a progress object", async () => {
    const remote = stored({ version: 2 });
    const server = new FakeServer().on("PUT", /progress$/, () => ({ status: 409, body: { account: ACCOUNT, error: "progress_conflict", progress: remote } }));
    const client = new ApiClient({ boot, guard: new AccountGuard(ACCOUNT), csrfToken: () => "token", fetcher: server.fetcher });
    const body: ProgressRequest = { ...place(0.2), observed_at: "2026-11-15T12:00:00.000Z", expected_version: 1, client_mutation_id: "m" };
    expect(await client.saveProgress("7", body)).toEqual({ kind: "conflict", progress: remote });
    expect(server.requests[0]?.headers["x-csrf-token"]).toBe("token");
    expect(server.requests[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
  });

  test("a saved place for another account locks the page instead of being accepted", async () => {
    const guard = new AccountGuard(ACCOUNT);
    const server = new FakeServer().on("PUT", /progress$/, () => ({ body: { account: "99", progress: stored() } }));
    const client = new ApiClient({ boot, guard, csrfToken: () => "token", fetcher: server.fetcher });
    await expect(client.saveProgress("7", { ...place(0.2), observed_at: "2026-11-15T12:00:00.000Z", expected_version: 0, client_mutation_id: "m" })).rejects.toThrow("The signed-in account changed");
    expect(guard.getState()).toEqual({ status: "account_changed" });
  });
});

function key(target: unknown, value: string, extra: Partial<KeyboardEvent> = {}): KeyboardEvent {
  return { key: value, target, defaultPrevented: false, isComposing: false, altKey: false, ctrlKey: false, metaKey: false, shiftKey: false, ...extra } as unknown as KeyboardEvent;
}

describe("reader keys", () => {
  test("arrow and page keys turn pages from the page, the book and buttons, never from editing controls or with modifiers", () => {
    document.body.innerHTML = '<button id="b">Next</button><select id="s"><option>1</option></select><input id="r" type="range"><textarea id="t"></textarea><div id="e" contenteditable="true"></div><div role="slider" id="v"></div>';
    expect(pageKey(key(document.body, "ArrowRight"))).toBe("next");
    expect(pageKey(key(document.body, "PageUp"))).toBe("previous");
    expect(pageKey(key(document.getElementById("b"), "ArrowLeft"))).toBe("previous");
    for (const id of ["s", "r", "t", "e", "v"]) expect(pageKey(key(document.getElementById(id), "ArrowRight"))).toBeNull();
    expect(pageKey(key(document.body, "ArrowRight", { altKey: true }))).toBeNull();
    expect(pageKey(key(document.body, "ArrowRight", { defaultPrevented: true }))).toBeNull();
    expect(pageKey(key(document.body, "ArrowRight", { isComposing: true }))).toBeNull();
  });

  test("Space plays or pauses only outside controls that already handle it", () => {
    document.body.innerHTML = '<button id="b">Play</button><a id="a" href="/x">x</a><input id="r" type="range">';
    expect(playKey(key(document.body, " "))).toBe(true);
    for (const id of ["b", "a", "r"]) expect(playKey(key(document.getElementById(id), " "))).toBe(false);
    expect(playKey(key(document.body, " ", { shiftKey: true }))).toBe(false);
  });
});

describe("Go reader links", () => {
  test("EPUBs and audiobooks open the Go reader; PDF and comic files do not", () => {
    expect(goReaderLink(detail(), "/preview")).toBe("/preview/library/7/read");
    expect(goReaderLink(detail({ action: "listen", book_type: "audiobook" }), "/preview")).toBe("/preview/library/7/read");
    expect(goReaderLink(detail({ files: [{ id: OTHER, filename: "b.pdf", format: "pdf", media_type: "application/pdf", size_bytes: 1, position: 0, page_count: null }] }), "/preview")).toBeNull();
    expect(goReaderLink(detail({ availability: "unavailable" }), "/preview")).toBeNull();
    expect(goSummaryReaderLink(summary(), "/preview")).toBe("/preview/library/7/read");
    expect(goSummaryReaderLink(summary({ format_label: "PDF" }), "/preview")).toBeNull();
    expect(goSummaryReaderLink(summary({ format_label: "Comic" }), "/preview")).toBeNull();
  });

  test("the reader address names exactly one book under the mount", () => {
    expect(readerPublicationId("/preview/library/12/read", "/preview")).toBe("12");
    for (const path of ["/preview/library/012/read", "/preview/library/12/read/", "/preview/library/12", "/other/library/12/read", "/preview/library/12/read?x"]) expect(readerPublicationId(path, "/preview")).toBeNull();
  });

  test("the engine must come from this server and expose the expected engine", async () => {
    await expect(loadEngine("https://evil.test/engine.js", async () => ({}))).rejects.toThrow("must come from this server");
    await expect(loadEngine("/preview/assets/reader-engine.js", async () => ({ ePub: 1 }))).rejects.toThrow("not the expected one");
    const imported: string[] = [];
    const purifier = Object.assign(() => undefined, { sanitize: () => "", addHook: () => undefined, removeHook: () => undefined });
    const engine = await loadEngine("/preview/assets/reader-engine.js?x=1", async (address) => {
      imported.push(address);
      return { ePub: () => null, DOMPurify: purifier };
    });
    expect(imported).toEqual(["/preview/assets/reader-engine.js"]);
    expect(typeof engine.ePub).toBe("function");
  });
});

class FakeAudio extends EventTarget {
  currentTime = 0;
  duration = 24;
  paused = true;
  ended = false;
  playbackRate = 1;
  defaultPlaybackRate = 1;
  src = "";
  reject: DOMException | null = null;
  load() {
    queueMicrotask(() => this.dispatchEvent(new Event("loadedmetadata")));
  }
  async play() {
    if (this.reject) throw this.reject;
    this.paused = false;
    this.dispatchEvent(new Event("playing"));
  }
  pause() {
    if (this.paused) return;
    this.paused = true;
    this.dispatchEvent(new Event("pause"));
  }
  getAttribute(name: string) {
    return name === "src" ? this.src : null;
  }
  removeAttribute() {
    this.src = "";
  }
}

describe("the audiobook player rules", () => {
  const tracks = [
    { id: ASSET, filename: "Part 1.wav", format: "wav", media_type: "audio/wav", size_bytes: 10, position: 0, url: "/preview/api/v1/accounts/42/library/8/assets/a" },
    { id: OTHER, filename: "Part 2.wav", format: "wav", media_type: "audio/wav", size_bytes: 10, position: 1, url: "/preview/api/v1/accounts/42/library/8/assets/b" },
  ];

  test("reopening restores silently, a refused play is shown without saving, and Play after a pause rewinds once without re-dating the saved place", async () => {
    const element = new FakeAudio();
    const recorded: unknown[] = [];
    const saved = stored({ asset_id: OTHER, locator: null, position_seconds: 12 });
    const player = new AudioSession(element as unknown as HTMLAudioElement, tracks, saved, { record: (value) => recorded.push(value), flush: () => undefined, failed: () => undefined });
    await settle();
    expect(player.getState()).toMatchObject({ track: 1, ready: true, position: 12 });
    expect(element.src).toBe(tracks[1]?.url ?? "");
    element.reject = new DOMException("blocked", "NotAllowedError");
    await player.play();
    expect(player.getState().problem).toBe("blocked");
    expect(element.currentTime).toBe(7);
    player.settle();
    expect(recorded).toEqual([]);
    element.reject = null;
    await player.play();
    expect(element.currentTime).toBe(7);
    element.currentTime = 10;
    player.pause();
    expect(recorded).toEqual([]);
    await player.play();
    element.currentTime = 13;
    player.pause();
    expect(recorded).toEqual([{ asset_id: OTHER, position_seconds: 13 }]);
    player.destroy();
  });

  test("seeking and choosing a track are deliberate places; a natural end continues on the next track", async () => {
    const element = new FakeAudio();
    const recorded: unknown[] = [];
    const player = new AudioSession(element as unknown as HTMLAudioElement, tracks, null, { record: (value) => recorded.push(value), flush: () => undefined, failed: () => undefined });
    await settle();
    player.seek(9);
    expect(recorded).toEqual([{ asset_id: ASSET, position_seconds: 9 }]);
    await player.play();
    element.currentTime = 24;
    element.paused = true;
    element.dispatchEvent(new Event("pause"));
    element.dispatchEvent(new Event("ended"));
    await settle();
    expect(recorded).toEqual([{ asset_id: ASSET, position_seconds: 9 }, { asset_id: ASSET, position_seconds: 24 }, { asset_id: OTHER, position_seconds: 0 }]);
    expect(player.getState().track).toBe(1);
    player.chooseTrack(0, false);
    expect(recorded.at(-1)).toEqual({ asset_id: ASSET, position_seconds: 0 });
    player.setRate(1.5);
    expect(recorded).toHaveLength(4);
    player.destroy();
  });
});
