import { z } from "zod";
import { ACCOUNT_HEADER } from "../api/client";
import type { AccountGuard } from "../api/account-guard";
import { errorEnvelopeSchema, type Locator, type PageEngine, type ProgressPlace, type ReaderAsset } from "../contract";
import { pageKey } from "./keys";
import { PageError, PageReader, restoredPage, type PageFormat, type PageResources, type PageZone } from "./shared";

export type PageView = { position: number; count: number; zoom: number; zoomed: boolean };

export type PageCallbacks = {
  view: (view: PageView) => void;
  moved: (place: ProgressPlace, at: number) => void;
  failed: (message: string | null) => void;
  unsure: () => void;
};

export type PageOpening = { count: number; exact: boolean; position: number };

export class PageEngineError extends Error {}

function isPdfEngine(value: unknown): boolean {
  if (typeof value !== "object" || value === null) return false;
  const engine = value as Record<string, unknown>;
  return typeof engine["getDocument"] === "function" && typeof engine["TextLayer"] === "function" && typeof engine["GlobalWorkerOptions"] === "function" && typeof engine["AnnotationMode"] === "object";
}

export function pdfEngineLoader(address: string, importer: (address: string) => Promise<unknown> = (target) => import(target)): () => Promise<unknown> {
  return async () => {
    const url = new URL(address, window.location.href);
    if (url.origin !== window.location.origin) throw new PageEngineError("The PDF renderer must come from this server.");
    let loaded: unknown;
    try {
      loaded = await importer(url.pathname);
    } catch {
      throw new PageEngineError("The PDF renderer could not be loaded. Check your connection, then reload the page.");
    }
    if (!isPdfEngine(loaded)) throw new PageEngineError("The PDF renderer on this server is not the expected one.");
    return loaded;
  };
}

export function pageResources(engine: PageEngine): PageResources {
  return { worker: engine.worker, files: engine.files };
}

type Fetcher = (input: string, init: RequestInit) => Promise<Response>;

const accountedSchema = z.looseObject({ account: z.string() });

export function guardedFetch(guard: AccountGuard, fetcher: Fetcher = (input, init) => fetch(input, init)): Fetcher {
  return async (input, init) => {
    guard.assertActive();
    const url = new URL(input, window.location.href);
    if (url.origin !== window.location.origin) throw new PageError("Pages must come from this server.");
    const headers = new Headers(init.headers);
    headers.set(ACCOUNT_HEADER, guard.account);
    const response = await fetcher(`${url.pathname}${url.search}`, { ...init, headers, credentials: "same-origin", cache: "no-store", redirect: "error", referrerPolicy: "no-referrer" });
    if (response.status === 401) {
      const envelope = errorEnvelopeSchema.safeParse(await response.clone().json().catch(() => null));
      const code = envelope.success ? envelope.data.error : null;
      if (code === "signed_out" || code === "account_changed") {
        guard.lock(code);
        throw new PageError("Sign in again to keep reading.", "signin");
      }
    }
    if (response.ok && !headers.has("Range")) {
      const answered = accountedSchema.safeParse(await response.clone().json().catch(() => null));
      if (!answered.success || answered.data.account !== guard.account) {
        guard.lock("account_changed");
        throw new PageError("Sign in again to keep reading.", "signin");
      }
    }
    guard.assertActive();
    return response;
  };
}

export function isPageFormat(format: string): format is PageFormat {
  return format === "pdf" || format === "cbz";
}

export class PageSession {
  private readonly asset: ReaderAsset;
  private readonly format: PageFormat;
  private readonly callbacks: PageCallbacks;
  private readonly now: () => number;
  private readonly reader: PageReader;
  private readonly zoomWatch: MutationObserver;
  private placed = 0;
  private turnAt: number | null = null;
  private ready = false;
  private active = true;

  constructor(
    element: HTMLElement,
    asset: ReaderAsset & { format: PageFormat },
    options: { resources: PageResources | null; fetch: Fetcher; loadEngine: (() => Promise<unknown>) | undefined },
    callbacks: PageCallbacks,
    now: () => number = () => Date.now(),
  ) {
    this.asset = asset;
    this.format = asset.format;
    this.callbacks = callbacks;
    this.now = now;
    this.reader = new PageReader({
      element,
      asset: { id: asset.id, size_bytes: asset.size_bytes, page_count: asset.page_count },
      format: asset.format,
      resources: options.resources,
      orderURL: asset.reading_order_url ?? null,
      label: "Page",
      fetch: options.fetch,
      ...(options.loadEngine ? { loadEngine: options.loadEngine } : {}),
      onChange: (position, count, change) => this.changed(position, count, change.shown),
      onTap: (zone) => this.tapped(zone),
      onError: (message) => this.callbacks.failed(message),
    });
    this.zoomWatch = new MutationObserver(() => this.report());
    this.zoomWatch.observe(element, { attributes: true, attributeFilter: ["data-zoom"] });
  }

  async open(saved: Locator | null): Promise<PageOpening> {
    const url = new URL(this.asset.url, window.location.href);
    if (url.origin !== window.location.origin) throw new PageError("This file must come from this server.");
    const count = await this.reader.open(url.href);
    if (!this.active) return { count, exact: true, position: 1 };
    if (this.format === "pdf") this.reader.page?.setAttribute("role", "group");
    const restored = restoredPage(this.format, saved, count, this.reader.items());
    await this.reader.show(restored.position);
    this.placed = restored.position;
    this.ready = this.active;
    return { count, exact: restored.exact, position: restored.position };
  }

  destroy(): void {
    this.active = false;
    this.ready = false;
    this.turnAt = null;
    this.zoomWatch.disconnect();
    this.reader.destroy();
  }

  next(): void {
    this.move(() => this.reader.next());
  }

  previous(): void {
    this.move(() => this.reader.previous());
  }

  go(position: number): void {
    if (!Number.isInteger(position) || position < 1 || position > this.reader.count) return;
    this.move(() => this.reader.go(position));
  }

  zoomIn(): Promise<void> {
    return this.zoomWith(() => this.reader.zoomIn());
  }

  zoomOut(): Promise<void> {
    return this.zoomWith(() => this.reader.zoomOut());
  }

  fitPage(): Promise<void> {
    return this.zoomWith(() => this.reader.fit());
  }

  showRemote(locator: Locator): Promise<void> {
    if (!this.ready) return Promise.resolve();
    this.forgetTurns();
    const restored = restoredPage(this.format, locator, this.reader.count, this.reader.items());
    this.placed = restored.position;
    return this.reader.show(restored.position);
  }

  key(event: KeyboardEvent): void {
    if (!this.ready) return;
    const direction = pageKey(event);
    if (!direction) return;
    const stage = this.reader.stage;
    if (this.reader.zoomed && stage && event.target instanceof Node && stage.contains(event.target) && event.key.startsWith("Arrow")) return;
    event.preventDefault();
    if (direction === "next") this.next();
    else this.previous();
  }

  forgetTurns(): void {
    this.turnAt = null;
    this.placed = 0;
  }

  private move(step: () => Promise<void> | undefined): void {
    if (!this.ready || !this.active) return;
    const at = this.now();
    const from = this.reader.position;
    const started = step();
    if (!started) return;
    const target = this.reader.position;
    if (target !== from) this.turnAt = at;
    started.then(
      () => this.settled(target),
      () => {
        if (!this.active) return;
        this.callbacks.failed("This page couldn't be opened.");
        this.callbacks.unsure();
      },
    );
  }

  private settled(target: number): void {
    if (this.active && this.reader.displayedPosition !== target) this.callbacks.unsure();
  }

  private zoomWith(step: () => Promise<void>): Promise<void> {
    if (!this.ready) return Promise.resolve();
    return step().then(() => this.report());
  }

  private changed(position: number, count: number, shown: boolean): void {
    if (!this.active) return;
    if (shown) this.callbacks.failed(null);
    this.report(position, count);
    if (!shown || !this.ready) return;
    const at = this.turnAt;
    if (position === this.placed) this.turnAt = null;
    if (position === this.placed || at === null) return;
    this.turnAt = null;
    this.placed = position;
    this.callbacks.moved({ asset_id: this.asset.id, locator: this.reader.locator(position) }, at);
  }

  private report(position = this.reader.position, count = this.reader.count): void {
    if (!this.active) return;
    const zoomed = this.reader.zoomed;
    const stage = this.reader.stage;
    if (stage) {
      if (zoomed) {
        stage.tabIndex = 0;
        stage.setAttribute("role", "region");
        stage.setAttribute("aria-label", "Zoomed page; use the arrow keys to move around it");
      } else {
        stage.removeAttribute("tabindex");
        stage.removeAttribute("role");
        stage.removeAttribute("aria-label");
      }
    }
    this.callbacks.view({ position, count, zoom: this.reader.zoom, zoomed });
  }

  private tapped(zone: PageZone): void {
    if (zone === "previous") this.previous();
    else if (zone === "next") this.next();
  }
}
