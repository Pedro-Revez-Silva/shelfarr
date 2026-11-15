import { describe, expect, test } from "bun:test";
import { bootSchema, libraryFiltersSchema, librarySchema, publicationDetailSchema, sessionSchema } from "../src/contract";
import { readBoot, readCsrfToken, BootError } from "../src/boot";
import { ACCOUNT, boot, detail, page, session, summary } from "./helpers";

describe("the browser contract", () => {
  test("accepts the shapes the server sends and ignores fields it adds later", () => {
    expect(librarySchema.parse({ ...page([summary()]), future: true }).items).toHaveLength(1);
    expect(sessionSchema.parse({ ...session(), future: 1 }).admin).toBeUndefined();
    expect(sessionSchema.parse(session({ admin: { url: "/sub/admin" } })).admin).toEqual({ url: "/sub/admin" });
    expect(publicationDetailSchema.parse(detail()).files[0]?.filename).toBe("A Book.epub");
  });

  test("keeps exact identity and activity times", () => {
    const progress = { asset_id: "f".repeat(64), position_seconds: 17.5, fraction: null, page: null, version: 3, observed_at: "2026-11-14T10:00:00.123Z", updated_at: "2026-11-14T10:00:05.000Z" };
    expect(publicationDetailSchema.parse(detail({ progress })).progress).toEqual(progress);
    expect(librarySchema.parse(page([summary({ id: "9223372036854775807" })])).items[0]?.id).toBe("9223372036854775807");
  });

  const bad: [string, unknown][] = [
    ["a numeric id", { ...summary(), id: 7 }],
    ["a zero id", { ...summary(), id: "0" }],
    ["an http cover", summary({ cover: { url: "http://covers.test/a.jpg", style: "clay" } })],
    ["a javascript cover", summary({ cover: { url: "javascript:alert(1)", style: "clay" } })],
    ["a cover with credentials", summary({ cover: { url: "https://u:p@covers.test/a.jpg", style: "clay" } })],
    ["a reader url on another host", summary({ reader_url: "https://evil.test/read/7" })],
    ["a protocol-relative reader url", summary({ reader_url: "//evil.test/read/7" })],
    ["an unknown status", { ...summary(), reading_status: "done" }],
    ["a missing availability", { ...summary(), availability: undefined }],
    ["a string version", summary({ progress: { asset_id: "a", position_seconds: null, fraction: null, page: null, version: "1" as unknown as number, observed_at: null, updated_at: "2026-11-14T10:00:05Z" } })],
    ["a fraction above one", summary({ progress: { asset_id: "a", position_seconds: null, fraction: 1.2, page: null, version: 1, observed_at: null, updated_at: "2026-11-14T10:00:05Z" } })],
    ["a malformed time", summary({ progress: { asset_id: "a", position_seconds: null, fraction: null, page: null, version: 1, observed_at: "yesterday", updated_at: "2026-11-14T10:00:05Z" } })],
  ];
  for (const [name, value] of bad) {
    test(`rejects ${name}`, () => {
      expect(librarySchema.safeParse({ account: ACCOUNT, items: [value], next_cursor: null }).success).toBe(false);
    });
  }

  test("a library page needs its account and cursor", () => {
    expect(librarySchema.safeParse({ items: [], next_cursor: null }).success).toBe(false);
    expect(librarySchema.safeParse({ account: ACCOUNT, items: [] }).success).toBe(false);
    expect(librarySchema.safeParse({ account: ACCOUNT, items: [], next_cursor: "" }).success).toBe(false);
  });

  test("filters from a pasted address fall back instead of failing", () => {
    expect(libraryFiltersSchema.parse({ q: "dune", type: "audiobook", status: "finished", sort: "title" })).toEqual({ q: "dune", type: "audiobook", status: "finished", sort: "title" });
    expect(libraryFiltersSchema.parse({ type: "film", status: "done", sort: "random", q: "x".repeat(201) })).toEqual({});
    expect(libraryFiltersSchema.parse({ q: 5, type: ["ebook"] })).toEqual({});
  });

  test("boot data binds the page to its account and mount", () => {
    expect(bootSchema.parse(boot)).toEqual(boot);
    expect(bootSchema.safeParse({ ...boot, version: 2 }).success).toBe(false);
    expect(bootSchema.safeParse({ ...boot, account: "abc" }).success).toBe(false);
    expect(bootSchema.safeParse({ ...boot, api: "https://evil.test" }).success).toBe(false);
  });

  test("reads the boot block and CSRF token from the document", () => {
    document.head.innerHTML = '<meta name="csrf-token" content="abc">';
    document.body.innerHTML = `<script type="application/json" id="shelfarr-boot">${JSON.stringify(boot)}</script>`;
    expect(readBoot(document)).toEqual(boot);
    expect(readCsrfToken(document)).toBe("abc");
    document.body.innerHTML = "";
    expect(() => readBoot(document)).toThrow(BootError);
    document.body.innerHTML = '<script type="application/json" id="shelfarr-boot">{nope</script>';
    expect(() => readBoot(document)).toThrow(BootError);
    document.body.innerHTML = '<script type="application/json" id="shelfarr-boot">{"version":1}</script>';
    expect(() => readBoot(document)).toThrow(BootError);
    document.head.innerHTML = "";
    expect(readCsrfToken(document)).toBeNull();
  });
});
