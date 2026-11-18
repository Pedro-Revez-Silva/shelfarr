import type { Locator, ProgressPlace } from "../contract";
import type { ReaderEngine } from "./engine";
import { places, type EpubBook, type EpubContents, type EpubLocation, type EpubNavItem, type EpubRendition } from "./shared";

export type Chapter = { href: string; label: string; depth: number };
export type EpubPosition = { page: number; total: number; chapter: number; href: string };

export type EpubCallbacks = {
  position: (position: EpubPosition) => void;
  moved: (place: ProgressPlace, at: number) => void;
  key: (event: KeyboardEvent) => void;
  failed: (message: string) => void;
};

export const FONT_SIZES = { min: 80, max: 180, step: 10, initial: 105 } as const;

const SWIPE_DISTANCE = 48;
const TAP_EDGE = 0.3;

function flatten(items: EpubNavItem[], depth = 0, into: Chapter[] = []): Chapter[] {
  for (const item of items) {
    into.push({ href: item.href, label: item.label.trim(), depth });
    flatten(item.subitems ?? [], depth + 1, into);
  }
  return into;
}

function usableLocator(locator: Locator | null): Locator | null {
  const cfi = locator?.locations?.cfi;
  if (!locator?.locations || cfi === undefined || (typeof cfi === "string" && cfi !== "")) return locator;
  const { cfi: _unusable, ...locations } = locator.locations;
  return { ...locator, locations };
}

export class EpubSession {
  private readonly engine: ReaderEngine;
  private readonly viewport: HTMLElement;
  private readonly assetId: string;
  private readonly callbacks: EpubCallbacks;
  private book: EpubBook | null = null;
  private rendition: EpubRendition | null = null;
  private ready = false;
  private moves: Promise<void> = Promise.resolve();
  private epoch = 0;
  private displayFailed: ((reason: unknown) => void) | null = null;
  private readingAnchor: string | undefined;
  private reflow: Promise<unknown> = Promise.resolve();
  private touchStart: { x: number; y: number } | null = null;
  private swiped = false;
  private active = true;
  private fontSize: number = FONT_SIZES.initial;
  private readonly now: () => number;

  constructor(engine: ReaderEngine, viewport: HTMLElement, assetId: string, callbacks: EpubCallbacks, now: () => number = () => Date.now()) {
    this.now = now;
    this.engine = engine;
    this.viewport = viewport;
    this.assetId = assetId;
    this.callbacks = callbacks;
  }

  async open(buffer: ArrayBuffer, locator: Locator | null, colors: { ink: string; surface: string }): Promise<Chapter[]> {
    const { ePub, DOMPurify } = this.engine;
    const book = ePub(undefined, { replacements: "blobUrl" });
    this.book = book;
    await book.open(buffer);
    if (!this.active) return [];
    const origin = window.location.origin;
    for (const section of book.spine.spineItems) {
      const render = section.render.bind(section);
      section.render = async (...args: unknown[]) => {
        section.output = places.sanitizeSection(DOMPurify, await render(...args), { images: places.ownBookImages(book, origin), base: places.sectionBase(book, section.href, origin) });
        return section.output;
      };
    }
    this.viewport.replaceChildren();
    const rendition = book.renderTo(this.viewport, { width: "100%", height: "100%", spread: "none", allowScriptedContent: false, allowPopups: false });
    this.rendition = rendition;
    rendition.themes.default({
      body: { color: `${colors.ink} !important`, background: `${colors.surface} !important`, "font-family": "Georgia, serif !important", "line-height": "1.7 !important" },
      a: { color: "inherit" },
    });
    rendition.themes.fontSize(`${this.fontSize}%`);
    rendition.on("relocated", (location) => this.relocated(location));
    rendition.on("resized", () => this.reflowed());
    rendition.on("displayerror", (reason) => this.displayFailed?.(reason));
    rendition.hooks.content.register((contents) => this.bookInput(contents));
    const chapters = flatten((await book.loaded.navigation).toc);
    await this.restore(locator);
    this.ready = true;
    return chapters;
  }

  destroy(): void {
    this.active = false;
    this.ready = false;
    this.book?.destroy();
    this.book = null;
    this.rendition = null;
  }

  next(): void {
    void this.move(() => this.rendition?.next(), "Couldn't open the next page.");
  }

  previous(): void {
    void this.move(() => this.rendition?.prev(), "Couldn't open the previous page.");
  }

  chooseChapter(href: string): void {
    void this.move(() => this.showTarget(href), "This chapter couldn't be opened.");
  }

  showRemote(locator: Locator): Promise<void> {
    this.epoch += 1;
    const shown = this.moves.then(() => this.restore(locator));
    this.moves = shown.catch(() => undefined);
    return shown;
  }

  changeTextSize(delta: number): Promise<number> {
    const change = this.reflow.then(async () => {
      const rendition = this.rendition;
      if (!this.active || !rendition || !this.ready) return this.fontSize;
      const anchor = this.layoutAnchor();
      this.fontSize = Math.max(FONT_SIZES.min, Math.min(FONT_SIZES.max, this.fontSize + delta));
      rendition.themes.fontSize(`${this.fontSize}%`);
      await places.settleFrames(rendition);
      if (!this.active) return this.fontSize;
      if (anchor) await rendition.display(anchor);
      await rendition.reportLocation();
      return this.fontSize;
    });
    this.reflow = change.catch(() => undefined);
    return change;
  }

  private archiveHref(href: string): string {
    return this.book ? this.book.resolve(href).replace(/^\/+/, "") : "";
  }

  private linkTarget(address: string): string | null {
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      return null;
    }
    if (url.origin !== window.location.origin) return null;
    let path: string;
    try {
      path = decodeURIComponent(url.pathname.replace(/%23/gi, "%2523"));
    } catch {
      return null;
    }
    return `${this.bookTarget(path)}${url.hash}`;
  }

  private bookTarget(href: string): string {
    const clean = String(href).replace(/^\/+/, "");
    return this.book ? this.book.path.relative(`/${clean}`) : clean;
  }

  private async restore(given: Locator | null): Promise<void> {
    const locator = usableLocator(given);
    await this.showLocator(locator);
    const fraction = places.restorableFraction(locator);
    const contents = fraction === null ? null : this.rendition?.getContents()[0];
    const restored = contents && fraction !== null ? places.fractionPlace(contents, fraction) : null;
    if (restored) await this.showPlace(restored);
  }

  private async showLocator(locator: Locator | null): Promise<void> {
    const cfi = locator?.locations?.cfi;
    if (typeof cfi === "string" && cfi) return this.showPlace(cfi);
    const target = locator?.href ? this.bookTarget(locator.href) : undefined;
    await this.showPlace(target);
    const fragment = places.fragmentOf(locator);
    if (!target || !fragment || !this.active || !locator) return;
    await this.showElement(this.contentsFor(locator.href), fragment);
  }

  private async showTarget(href: string): Promise<void> {
    const hash = href.indexOf("#");
    if (hash < 0) return this.showPlace(href);
    await this.showPlace(href.slice(0, hash));
    const rendition = this.rendition;
    const index = rendition?.currentLocation()?.start?.index;
    const contents = rendition?.getContents().find((item) => item.sectionIndex === index) ?? null;
    await this.showElement(contents, decodeURIComponent(href.slice(hash + 1)));
  }

  private async showElement(contents: EpubContents | null, fragment: string): Promise<void> {
    if (!contents || !fragment || !this.active) return;
    const element = contents.document.getElementById(`user-content-${fragment}`) ?? contents.document.getElementById(fragment);
    if (element) await this.showPlace(places.elementCfi(contents, element));
  }

  private contentsFor(href: string): EpubContents | null {
    const book = this.book;
    const rendition = this.rendition;
    if (!book || !rendition) return null;
    return (
      rendition.getContents().find((contents) => {
        const section = book.spine.get(contents.sectionIndex);
        return section !== null && this.archiveHref(section.href) === href;
      }) ?? null
    );
  }

  private async showPlace(target: string | undefined): Promise<void> {
    const rendition = this.rendition;
    if (!rendition) return;
    await rendition.display(target);
    if (target && this.active) {
      await places.settleFrames(rendition);
      if (this.active) await rendition.display(target);
    }
    if (this.active) {
      const cfi = typeof target === "string" && target.startsWith("epubcfi(") ? target : this.pageCfi();
      if (cfi) this.readingAnchor = cfi;
    }
  }

  private pageCfi(location?: EpubLocation): string | undefined {
    const rendition = this.rendition;
    if (!rendition) return undefined;
    return places.pageCfi(rendition, this.viewport, location ?? rendition.currentLocation());
  }

  private layoutAnchor(): string | undefined {
    return this.readingAnchor ?? this.rendition?.location?.start?.cfi ?? this.rendition?.currentLocation()?.start?.cfi;
  }

  private reflowed(): void {
    if (!this.ready) return;
    const anchor = this.layoutAnchor();
    if (!anchor) return;
    this.reflow = this.reflow.then(() => (this.active ? this.showPlace(anchor) : undefined)).catch(() => undefined);
  }

  private move(step: () => Promise<unknown> | undefined, message: string): Promise<void> {
    const started = this.now();
    const epoch = this.epoch;
    const run = this.moves.then(async () => {
      try {
        let pending: Promise<unknown>;
        do {
          pending = this.reflow;
          await pending;
        } while (pending !== this.reflow);
        if (!this.active || !this.ready || epoch !== this.epoch) return;
        const before = this.pageCfi();
        await this.settled(step);
        if (this.active && epoch === this.epoch) this.reached(before, started);
      } catch {
        if (this.active) this.callbacks.failed(message);
      }
    });
    this.moves = run;
    return run;
  }

  private settled(step: () => Promise<unknown> | undefined): Promise<unknown> {
    return new Promise((resolve, reject) => {
      this.displayFailed = reject;
      Promise.resolve(step()).then(resolve, reject);
    }).finally(() => {
      this.displayFailed = null;
    });
  }

  private reached(before: string | undefined, at: number): void {
    const book = this.book;
    const location = this.rendition?.currentLocation();
    const start = location?.start;
    const cfi = this.pageCfi(location);
    if (!book || !start || !cfi) return;
    this.readingAnchor = cfi;
    if (cfi === before) return;
    const { fraction, total } = places.pageProgression(start, book.spine.length);
    this.callbacks.moved({ asset_id: this.assetId, locator: { href: this.archiveHref(start.href), type: "application/xhtml+xml", locations: { progression: fraction, totalProgression: total, cfi } } }, at);
  }

  private relocated(location: EpubLocation): void {
    if (!this.active || !this.book) return;
    const start = location.start;
    this.callbacks.position({ page: start.displayed.page, total: start.displayed.total, chapter: start.index + 1, href: start.href });
  }

  private bookInput(contents: EpubContents): void {
    const document = contents.document;
    const frame = contents.window.frameElement;
    frame?.setAttribute("title", "Book text");
    document.addEventListener("keydown", (event) => this.callbacks.key(event));
    for (const link of document.querySelectorAll<HTMLAnchorElement>("a[href]")) {
      link.onclick = (event) => {
        event.preventDefault();
        const target = this.linkTarget(link.href);
        if (target) void this.move(() => this.showTarget(target), "This link couldn't be opened.");
        return false;
      };
    }
    document.addEventListener("click", (event) => {
      if ((event.target as Element | null)?.closest?.("a[href]")) return;
      if (this.swiped) {
        this.swiped = false;
        return;
      }
      const selection = contents.window.getSelection();
      if (selection && !selection.isCollapsed) return;
      const bounds = this.viewport.getBoundingClientRect();
      const x = (frame?.getBoundingClientRect().left ?? 0) + event.clientX - bounds.left;
      const zone = x / Math.max(1, bounds.width);
      if (zone < TAP_EDGE) this.previous();
      else if (zone > 1 - TAP_EDGE) this.next();
    });
    document.addEventListener(
      "touchstart",
      (event) => {
        const touch = event.changedTouches[0];
        this.touchStart = touch ? { x: touch.clientX, y: touch.clientY } : null;
      },
      { passive: true },
    );
    document.addEventListener(
      "touchend",
      (event) => {
        const touch = event.changedTouches[0];
        const start = this.touchStart;
        this.touchStart = null;
        if (!touch || !start) return;
        const dx = touch.clientX - start.x;
        const dy = touch.clientY - start.y;
        const selection = contents.window.getSelection();
        if (Math.abs(dx) < SWIPE_DISTANCE || Math.abs(dx) < Math.abs(dy) * 1.5 || (selection && !selection.isCollapsed)) return;
        this.swiped = true;
        setTimeout(() => {
          this.swiped = false;
        }, 400);
        if (dx < 0) this.next();
        else this.previous();
      },
      { passive: true },
    );
  }
}
