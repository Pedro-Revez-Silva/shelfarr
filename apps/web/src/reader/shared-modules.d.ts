declare module "*/app/javascript/consumer_epub_places.js" {
  export type EpubPoint = { cfi: string; href: string; index: number; displayed: { page: number; total: number } };
  export type EpubLocation = { start: EpubPoint; end?: EpubPoint; atStart?: boolean; atEnd?: boolean };

  export interface EpubContents {
    document: Document;
    window: Window;
    sectionIndex: number;
    cfiFromNode(node: Node): string;
    cfiFromRange(range: Range): string;
  }

  export interface EpubView {
    expand?: () => void;
    contents?: { document?: Document };
  }

  export interface EpubRendition {
    display(target?: string): Promise<unknown>;
    next(): Promise<unknown>;
    prev(): Promise<unknown>;
    on(event: "relocated", listener: (location: EpubLocation) => void): void;
    on(event: "resized", listener: () => void): void;
    hooks: { content: { register(hook: (contents: EpubContents) => void): void } };
    themes: { default(rules: Record<string, Record<string, string>>): void; fontSize(size: string): void };
    getContents(): EpubContents[];
    currentLocation(): EpubLocation | undefined;
    location?: EpubLocation;
    getRange(cfi: string): Range;
    views(): { all?: () => EpubView[] };
    reportLocation(): Promise<unknown>;
  }

  export type EpubNavItem = { href: string; label: string; subitems?: EpubNavItem[] };

  export interface EpubSection {
    href: string;
    index: number;
    output?: string;
    render(...args: unknown[]): Promise<string>;
  }

  export interface EpubBook {
    open(input: ArrayBuffer): Promise<unknown>;
    spine: { length: number; spineItems: EpubSection[]; get(index: number): EpubSection | null };
    loaded: { navigation: Promise<{ toc: EpubNavItem[] }> };
    resolve(href: string): string;
    path: { relative(path: string): string };
    renderTo(element: Element, options: { width: string; height: string; spread: "none"; allowScriptedContent: false; allowPopups: false }): EpubRendition;
    destroy(): void;
    resources?: { replacementUrls?: unknown[] };
  }

  export interface Purifier {
    addHook(entry: "uponSanitizeAttribute", hook: (node: Element, data: { attrName: string; attrValue: string; forceKeepAttr?: boolean }) => void): void;
    removeHook(entry: "uponSanitizeAttribute", hook?: unknown): unknown;
    sanitize(html: string, options: Record<string, unknown>): string;
  }

  export type FragmentLocator = { locations?: { cfi?: unknown; progression?: number | null; fragments?: unknown } | null } | null | undefined;

  export function ownBookImages(book: EpubBook, origin: string): Set<string>;
  export function sanitizeSection(purifier: Purifier, html: string, options: { images: Set<string>; base: string }): string;
  export function sectionBase(book: EpubBook, href: string, origin: string): string;
  export function fragmentOf(locator: FragmentLocator): string | null;
  export function restorableFraction(locator: FragmentLocator): number | null;
  export function fractionPlace(contents: EpubContents, progression: number): string | null;
  export function elementCfi(contents: EpubContents, element: Element): string;
  export function settleFrames(rendition: EpubRendition): Promise<void>;
  export function pageCfi(rendition: EpubRendition, viewport: Element, location: EpubLocation | undefined): string | undefined;
  export function textOnPage(range: Range | null, onPage: (rect: DOMRect) => boolean): boolean;
  export function pageProgression(start: EpubPoint, spineLength: number): { fraction: number; total: number };
}

declare module "*/app/javascript/consumer_progress_sync.js" {
  export type ListeningPlace = { asset_id: string; position_seconds: number };

  export class ListeningCheckpoints {
    static INTERVAL: number;
    static REWIND: number;
    active: boolean;
    floor: number | null;
    skipRewind: boolean;
    constructor(options: { record: (place: ListeningPlace) => void; now?: () => number });
    restored(position: number, assetId: string): void;
    resume(position: number): number;
    deliberate(position: number, assetId: string, paused: boolean): void;
    continued(assetId: string, position?: number): void;
    tick(position: number, assetId: string): boolean;
    settle(position: number, assetId: string): boolean;
  }

  export function plausibleObservedAt(value: unknown, now: number): number | null;
  export function samePlace(left: unknown, right: unknown): boolean;
}
