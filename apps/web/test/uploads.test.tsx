import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ServerSettings } from "../src/server/contract";
import { uploadsSchema, type Upload, type Uploads } from "../src/uploads/contract";
import { formatBytes, selectionText, supported } from "../src/uploads/files";
import { ACCOUNT, boot, FakeServer, renderApp, session, standardServer } from "./helpers";

afterEach(cleanup);

const ADMIN = { admin: { url: "/sub/admin" }, capabilities: { administrator: true, can_upload: true, single_sign_on: false, hardcover_personal_access: false } };
const FORMATS = { audiobook: ["m4b", "mp3", "zip"], ebook: ["epub", "pdf"], comicbook: ["cbz"] };

function upload(overrides: Partial<Upload> = {}): Upload {
  return {
    id: "3",
    filename: "Ursula K. Le Guin - The Dispossessed.epub",
    size: 2_400_000,
    book_type: "ebook",
    status: "completed",
    created_at: "2026-11-20T08:00:00.000Z",
    processed_at: "2026-11-20T08:01:00.000Z",
    parsed: { title: "The Dispossessed", author: "Ursula K. Le Guin", confidence: 91 },
    book: { title: "The Dispossessed", author: "Ursula K. Le Guin", acquired: true, publication_id: "44" },
    request_id: null,
    uploaded_by_you: true,
    failure: null,
    ...overrides,
  };
}

function failedUpload(overrides: Partial<Upload> = {}): Upload {
  return upload({
    id: "9",
    filename: "unrecognized.m4b",
    book_type: "audiobook",
    status: "failed",
    processed_at: null,
    parsed: { title: "Unrecognized", author: null, confidence: 12 },
    book: null,
    uploaded_by_you: false,
    failure: "No matching book",
    uploaded_by: "Rae Reader",
    manual_match: false,
    reserved_file: false,
    actions: { retry: true, match: true, remove: true },
    ...overrides,
  });
}

function listing(items: Upload[], overrides: Partial<Uploads> = {}): Uploads {
  return { account: ACCOUNT, can_upload: true, formats: FORMATS, max_bytes: 10 * 1024 ** 3, page: 1, per_page: 50, total: items.length, total_pages: 1, items, ...overrides };
}

function memberServer(current: () => Uploads): FakeServer {
  return standardServer().on("GET", /\/api\/v1\/uploads(\?|$)/, () => ({ body: current() }));
}

function adminServer(current: () => Uploads): FakeServer {
  return memberServer(current).on("GET", /\/api\/v1\/session$/, () => ({ body: session(ADMIN) }));
}

function file(name: string, type = "application/epub+zip", size = 12): File {
  return new File([new Uint8Array(size)], name, { type });
}

function sentForm(server: FakeServer): FormData {
  const body = server.called("POST", /\/api\/v1\/uploads$/)[0]?.body;
  if (!(body instanceof FormData)) throw new Error("no form was sent");
  return body;
}

describe("upload selection", () => {
  test("keeps only supported files from a folder and describes the selection", () => {
    const files = [file("Book.EPUB"), file("cover.jpg", "image/jpeg"), file("Part 1.m4b", "audio/mp4"), file("notes")];
    expect(supported(files, FORMATS).map((entry) => entry.name)).toEqual(["Book.EPUB", "Part 1.m4b"]);
    expect(selectionText({ files: [files[0]!], folder: false })).toBe("Book.EPUB");
    expect(selectionText({ files, folder: false })).toBe("4 files selected");
    expect(selectionText({ files: [files[0]!], folder: true })).toBe("1 supported file selected from the folder");
    expect([formatBytes(1), formatBytes(2_400_000), formatBytes(10 * 1024 ** 3)]).toEqual(["1 byte", "2.3 MB", "10 GB"]);
  });

  test("the fixtures match the uploads contract", () => {
    expect(uploadsSchema.safeParse(listing([upload(), failedUpload()])).success).toBe(true);
  });
});

describe("Library ▸ Uploads for a member", () => {
  test("lists the shared uploads with safe details and no administration", async () => {
    const server = memberServer(() => listing([upload(), upload({ id: "4", filename: "other.epub", uploaded_by_you: false, status: "failed", book: null, failure: "This file could not be added to the library. An administrator can retry it.", request_id: "7" })]));
    renderApp({ server, url: "/sub/preview/library/uploads" });

    const row = (await screen.findByRole("article", { name: "Ursula K. Le Guin - The Dispossessed.epub" })) as HTMLElement;
    expect(within(row).getByText("Completed")).toBeTruthy();
    expect(within(row).getByText("The Dispossessed by Ursula K. Le Guin · 91% confident")).toBeTruthy();
    expect(within(row).getByRole("link", { name: "The Dispossessed" }).getAttribute("href")).toBe("/sub/preview/library/44");
    expect(within(row).getByText(/Uploaded by you/)).toBeTruthy();
    const other = screen.getByRole("article", { name: "other.epub" });
    expect(within(other).getByText("This file could not be added to the library. An administrator can retry it.")).toBeTruthy();
    expect(within(other).getByRole("link", { name: "Open the request this file fulfils for other.epub" }).getAttribute("href")).toBe("/sub/preview/requests/7");
    expect(within(other).queryByText(/Uploaded by/)).toBeNull();
    expect(screen.queryByRole("button", { name: /Retry|Delete|Correct the match/ })).toBeNull();
    expect(screen.getByRole("heading", { name: "Uploads on this server", level: 2 })).toBeTruthy();
    expect(server.requests.some((request) => request.path.includes("/admin/"))).toBe(false);
  });

  test("says uploads are off instead of offering the form", async () => {
    renderApp({ server: memberServer(() => listing([], { can_upload: false })), url: "/sub/preview/library/uploads" });
    expect(await screen.findByText("Uploads are not currently enabled. An administrator can turn them on in Server ▸ People and access.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Upload" })).toBeNull();
    expect(screen.getByText(/No uploads yet/)).toBeTruthy();
  });

  test("sends chosen files as a multipart form with the account and CSRF headers and shows the result", async () => {
    let items: Upload[] = [];
    const server = memberServer(() => listing(items)).on("POST", /\/api\/v1\/uploads$/, () => {
      items = [upload({ id: "5", status: "pending", processed_at: null, parsed: null, book: null })];
      return { status: 201, body: { account: ACCOUNT, notice: "2 files uploaded successfully. Processing started.", alert: "1 file failed to upload: notes.txt: Unsupported file type", uploads: ["5", "6"] } };
    });
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup({ applyAccept: false });

    await user.click(await screen.findByRole("button", { name: "Upload" }));
    expect((await screen.findByRole("alert")).textContent).toBe("Choose at least one file or a folder to upload.");
    expect(server.called("POST", /uploads$/)).toHaveLength(0);

    await user.upload(screen.getByLabelText("Choose files"), [file("A.epub"), file("B.m4b", "audio/mp4")]);
    expect(screen.getByText("Selected: 2 files selected")).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Upload" }));

    expect(await screen.findByText("2 files uploaded successfully. Processing started.")).toBeTruthy();
    expect(screen.getByText("1 file failed to upload: notes.txt: Unsupported file type")).toBeTruthy();
    const sent = server.called("POST", /\/api\/v1\/uploads$/)[0]!;
    expect(sent.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(sent.headers["x-csrf-token"]).toBe("token-123");
    expect(sent.headers["content-type"]).toBeUndefined();
    const form = sentForm(server);
    expect(form.get("upload_mode")).toBe("files");
    expect((form.getAll("files[]") as File[]).map((entry) => entry.name)).toEqual(["A.epub", "B.m4b"]);
    expect(form.has("request_id")).toBe(false);
    expect(await screen.findByRole("article", { name: "Ursula K. Le Guin - The Dispossessed.epub" })).toBeTruthy();
    expect(screen.getByText("Waiting to process")).toBeTruthy();
  });

  test("a folder sends only its supported files in folder mode", async () => {
    const server = memberServer(() => listing([])).on("POST", /\/api\/v1\/uploads$/, () => ({ status: 201, body: { account: ACCOUNT, notice: "1 file uploaded successfully. Processing started.", uploads: ["5"] } }));
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup({ applyAccept: false });

    await user.upload(await screen.findByLabelText("Choose a folder"), [file("cover.jpg", "image/jpeg")]);
    expect(screen.getByText("No supported book files were found in that folder.")).toBeTruthy();
    await user.upload(screen.getByLabelText("Choose a folder"), [file("cover.jpg", "image/jpeg"), file("Book.epub")]);
    expect(screen.getByText("Selected: 1 supported file selected from the folder")).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Upload" }));
    await screen.findByText("1 file uploaded successfully. Processing started.");
    const form = sentForm(server);
    expect(form.get("upload_mode")).toBe("folder");
    expect((form.getAll("files[]") as File[]).map((entry) => entry.name)).toEqual(["Book.epub"]);
  });

  test("shows the server's refusal and keeps the selection for another try", async () => {
    const server = memberServer(() => listing([])).on("POST", /\/api\/v1\/uploads$/, () => ({ status: 422, body: { error: "upload_rejected", message: "Unsupported file type. Supported: m4b, epub" } }));
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup({ applyAccept: false });
    await user.upload(await screen.findByLabelText("Choose files"), [file("notes.txt", "text/plain")]);
    await user.click(screen.getByRole("button", { name: "Upload" }));
    const alert = await screen.findByText("Unsupported file type. Supported: m4b, epub");
    expect(document.activeElement).toBe(alert);
    expect(screen.getByText("Selected: notes.txt")).toBeTruthy();
  });

  test("refuses a file over the size limit before sending it", async () => {
    const server = memberServer(() => listing([], { max_bytes: 10 }));
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup({ applyAccept: false });
    await user.upload(await screen.findByLabelText("Choose files"), [file("Big.epub", "application/epub+zip", 11)]);
    await user.click(screen.getByRole("button", { name: "Upload" }));
    expect(await screen.findByText("Big.epub is larger than Shelfarr's 10 bytes limit.")).toBeTruthy();
    expect(server.called("POST", /uploads$/)).toHaveLength(0);
  });
});

describe("uploading for a request", () => {
  const context = { id: "7", title: "The Dispossessed", author: "Ursula K. Le Guin", book_type: "ebook" as const, open: true, message: null };

  test("offers one file for an open request and links back to it", async () => {
    let fulfilled = false;
    const server = memberServer(() => listing([]))
      .on("GET", /\/api\/v1\/uploads\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: fulfilled ? { ...context, open: false, message: "This request is already completed." } : context } }))
      .on("POST", /\/api\/v1\/uploads$/, () => {
        fulfilled = true;
        return { status: 201, body: { account: ACCOUNT, notice: "File uploaded successfully. Processing started.", uploads: ["5"], request_id: "7" } };
      });
    renderApp({ server, url: "/sub/preview/library/uploads?request=7" });
    const user = userEvent.setup({ applyAccept: false });

    expect(await screen.findByRole("heading", { name: "Upload a file for this request", level: 2 })).toBeTruthy();
    expect(screen.getByText(/This file will fulfil/).textContent).toBe("This file will fulfil The Dispossessed by Ursula K. Le Guin as the ebook request once processing succeeds.");
    const input = screen.getByLabelText("Choose a file") as HTMLInputElement;
    expect(input.multiple).toBe(false);
    expect(input.name).toBe("file");
    expect(screen.queryByLabelText("Choose a folder")).toBeNull();

    await user.upload(input, file("The Dispossessed.epub"));
    await user.click(screen.getByRole("button", { name: "Upload" }));
    const done = await screen.findByText(/File uploaded successfully/);
    expect(within(done).getByRole("link", { name: "Back to the request" }).getAttribute("href")).toBe("/sub/preview/requests/7");
    const form = sentForm(server);
    expect(form.get("request_id")).toBe("7");
    expect((form.get("file") as File).name).toBe("The Dispossessed.epub");
    expect(form.has("files[]")).toBe(false);
    expect(form.has("upload_mode")).toBe(false);
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/uploads$/).length).toBeGreaterThan(1));
    expect(screen.getByText(/File uploaded successfully/)).toBeTruthy();
    expect(server.called("GET", /uploads\/requests\/7$/)).toHaveLength(1);
  });

  test("explains a request that no longer takes files and offers no form", async () => {
    const server = memberServer(() => listing([])).on("GET", /\/api\/v1\/uploads\/requests\/7$/, () => ({ body: { account: ACCOUNT, request: { ...context, open: false, message: "This request is already completed." } } }));
    renderApp({ server, url: "/sub/preview/library/uploads?request=7" });
    expect(await screen.findByText("This request is already completed.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Upload" })).toBeNull();
  });

  test("a request that is not yours reads as not found", async () => {
    renderApp({ server: memberServer(() => listing([])), url: "/sub/preview/library/uploads?request=7" });
    expect(await screen.findByText("That request can't be found, or it belongs to another account.")).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Upload" })).toBeNull();
  });
});

describe("upload administration", () => {
  test("retries, deletes in two steps and reports each outcome", async () => {
    let items = [failedUpload()];
    const server = adminServer(() => listing(items))
      .on("POST", /\/admin\/uploads\/9\/retry$/, () => {
        items = [failedUpload({ status: "pending", failure: null, actions: { retry: false, match: false, remove: true } })];
        return { body: { account: ACCOUNT, outcome: { tone: "success", message: "Upload queued for retry." } } };
      })
      .on("DELETE", /\/admin\/uploads\/9$/, () => ({ status: 409, body: { error: "upload_refused", message: "This upload has a reserved library file and cannot be deleted safely. Retry the upload so Shelfarr can reconcile it first." } }));
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup();

    const row = (await screen.findByRole("article", { name: "unrecognized.m4b" })) as HTMLElement;
    expect(within(row).getByText(/Uploaded by Rae Reader/)).toBeTruthy();
    expect(within(row).getByText("No matching book")).toBeTruthy();
    expect(screen.getByRole("heading", { name: "All uploads", level: 2 })).toBeTruthy();

    await user.click(within(row).getByRole("button", { name: "Delete" }));
    await user.click(within(row).getByRole("button", { name: "Delete upload" }));
    expect(await screen.findByText("This upload has a reserved library file and cannot be deleted safely. Retry the upload so Shelfarr can reconcile it first.")).toBeTruthy();
    expect(server.called("DELETE", /uploads\/9$/)[0]?.headers["x-csrf-token"]).toBe("token-123");

    await user.click(within(screen.getByRole("article", { name: "unrecognized.m4b" })).getByRole("button", { name: "Retry unrecognized.m4b" }));
    expect(await screen.findByText("Upload queued for retry.")).toBeTruthy();
    await waitFor(() => expect(screen.getByText("Waiting to process")).toBeTruthy());
    expect(screen.queryByRole("button", { name: "Retry unrecognized.m4b" })).toBeNull();
  });

  test("a deleted upload leaves the list and focus moves to its heading", async () => {
    let items = [failedUpload()];
    const server = adminServer(() => listing(items)).on("DELETE", /\/admin\/uploads\/9$/, () => {
      items = [];
      return { body: { account: ACCOUNT, outcome: { tone: "success", message: "Upload deleted." } } };
    });
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup();
    const row = (await screen.findByRole("article", { name: "unrecognized.m4b" })) as HTMLElement;
    await user.click(within(row).getByRole("button", { name: "Delete" }));
    await user.click(within(row).getByRole("button", { name: "Delete upload" }));
    expect(await screen.findByText("Upload deleted.")).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole("article", { name: "unrecognized.m4b" })).toBeNull());
    expect(document.activeElement).toBe(screen.getByRole("heading", { name: "All uploads" }));
  });

  test("corrects a match with a local book or a new one", async () => {
    let items = [failedUpload()];
    const matches = { account: ACCOUNT, book_type: "audiobook" as const, query: "Unrecognized", page: 1, more: true, books: [{ id: "21", title: "Unrecognized Saga", author: "A. Writer" }], manual_book: { title: "Unrecognized", author: "" } };
    const server = adminServer(() => listing(items))
      .on("GET", /\/admin\/uploads\/9\/matches/, (request) => ({ body: request.path.includes("q=zzz") ? { ...matches, query: "zzz", more: false, books: [] } : request.path.includes("page=2") ? { ...matches, page: 2, more: false, books: [{ id: "22", title: "Unrecognized Two", author: null }] } : matches }))
      .on("POST", /\/admin\/uploads\/9\/match$/, (request) => {
        if ((request.body as { manual_book?: unknown }).manual_book) return { status: 422, body: { error: "match_rejected", message: "Title can't be blank" } };
        items = [failedUpload({ status: "pending", failure: null, manual_match: true, actions: { retry: false, match: false, remove: true } })];
        return { body: { account: ACCOUNT, outcome: { tone: "success", message: "Manual match saved. Upload queued for retry." } } };
      });
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup();

    const row = (await screen.findByRole("article", { name: "unrecognized.m4b" })) as HTMLElement;
    const toggle = within(row).getByRole("button", { name: "Correct the match for unrecognized.m4b" });
    await user.click(toggle);
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    const panel = (await within(row).findByRole("region", { name: "Correct the match and retry" })) as HTMLElement;
    expect(await within(panel).findByText("Unrecognized Saga by A. Writer")).toBeTruthy();
    expect((within(panel).getByLabelText("Search local books by title or author") as HTMLInputElement).value).toBe("Unrecognized");
    expect(within(panel).getByText(/Choose a local audiobook or create one/)).toBeTruthy();

    await user.click(within(panel).getByRole("button", { name: "Next matches" }));
    expect(await within(panel).findByText("Unrecognized Two")).toBeTruthy();
    const search = within(panel).getByLabelText("Search local books by title or author");
    await user.clear(search);
    await user.type(search, "zzz");
    await user.click(within(panel).getByRole("button", { name: "Search books" }));
    expect(await within(panel).findByText("No available books found. Try another search or create a book below.")).toBeTruthy();
    expect(server.called("GET", /matches\?q=zzz$/)).toHaveLength(1);

    await user.click(within(panel).getByText("Create a book with corrected details"));
    await user.clear(within(panel).getByLabelText("Title"));
    await user.type(within(panel).getByLabelText("Title"), "Corrected");
    await user.type(within(panel).getByLabelText("Author (optional)"), "Writer");
    await user.click(within(panel).getByRole("button", { name: "Create book and retry" }));
    expect(await within(panel).findByText("Title can't be blank")).toBeTruthy();
    expect(server.called("POST", /match$/)[0]?.body).toEqual({ manual_book: { title: "Corrected", author: "Writer" } });

    await user.clear(search);
    await user.click(within(panel).getByRole("button", { name: "Search books" }));
    await user.click(await within(panel).findByRole("button", { name: "Select and retry with Unrecognized Saga" }));
    expect(await screen.findByText("Manual match saved. Upload queued for retry.")).toBeTruthy();
    expect(server.called("POST", /match$/)[1]?.body).toEqual({ book_id: "21" });
    await waitFor(() => expect(screen.queryByRole("region", { name: "Correct the match and retry" })).toBeNull());
    expect(screen.getByText("Matched by hand")).toBeTruthy();
  });

  test("losing the administrator role hides the actions after the server refuses", async () => {
    let admin = true;
    const server = adminServer(() => listing([failedUpload()]))
      .on("GET", /\/api\/v1\/session$/, () => ({ body: session(admin ? ADMIN : {}) }))
      .on("POST", /\/admin\/uploads\/9\/retry$/, () => {
        admin = false;
        return { status: 404, body: { error: "not_found" } };
      });
    renderApp({ server, url: "/sub/preview/library/uploads" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Retry unrecognized.m4b" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Retry unrecognized.m4b" })).toBeNull());
    expect(screen.queryByText(/Rae Reader/)).toBeNull();
    expect(screen.queryByText("No matching book")).toBeNull();
  });
});

describe("Server ▸ Library and files", () => {
  function settingsFixture(): ServerSettings {
    const empty = (id: ServerSettings["categories"][number]["id"], title: string) => ({ id, title, summary: `${title}.`, groups: [] });
    return {
      account: ACCOUNT,
      categories: [empty("policy", "Request policy"), empty("sources", "Catalogues and sources"), empty("downloads", "Downloads"), empty("library", "Library and files"), empty("notifications", "Notifications"), empty("people", "People and access"), empty("system", "System")],
      notes: { path_variables: "", hardcover_app: { create_url: "https://hardcover.app/x", scopes: "read", redirect_uri: "https://shelf.test/cb", redirect_uri_acceptable: true } },
      roles: [],
    };
  }

  test("shows every upload with its actions in an Uploads card", async () => {
    const server = adminServer(() => listing([failedUpload()], { total: 51, total_pages: 2 })).on("GET", /\/api\/v1\/admin\/settings$/, () => ({ body: settingsFixture() }));
    renderApp({ server, url: "/sub/preview/server/library" });
    const user = userEvent.setup();
    const card = (await screen.findByRole("region", { name: "Uploads" })) as HTMLElement;
    expect(card.id).toBe("uploads");
    expect(screen.getByRole("navigation", { name: "Library and files cards" }).querySelector('a[href="#uploads"]')).toBeTruthy();
    expect(within(card).getByRole("link", { name: "Add a book" }).getAttribute("href")).toBe("/sub/preview/library/uploads");
    expect(await within(card).findByRole("heading", { name: "unrecognized.m4b", level: 5 })).toBeTruthy();
    expect(within(card).getByRole("button", { name: "Retry unrecognized.m4b" })).toBeTruthy();
    await user.click(within(card).getByRole("button", { name: "Next page" }));
    await waitFor(() => expect(server.called("GET", /\/api\/v1\/uploads\?page=2$/)).toHaveLength(1));
  });
});

describe("outside Rails", () => {
  test("the Go runtime says the page is not part of it", async () => {
    renderApp({ server: new FakeServer().on("GET", /\/api\/v1\/session$/, () => ({ body: session() })), url: "/sub/preview/library/uploads", boot: { ...boot, runtime: "go" } as typeof boot });
    expect(await screen.findByText("That page is not part of this preview")).toBeTruthy();
  });
});
