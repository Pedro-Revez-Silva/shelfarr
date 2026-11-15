import { describe, expect, test } from "bun:test";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ACCOUNT, deferred, detail, renderApp, standardServer } from "./helpers";

const progress = { asset_id: "b".repeat(64), position_seconds: 17.5, fraction: null, page: null, version: 2, observed_at: "2026-11-14T10:00:00.000Z", updated_at: "2026-11-14T10:00:05.000Z" };

function detailsServer(publication = detail()) {
  return standardServer().on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication } }));
}

describe("the publication details", () => {
  test("show the book, a real Read link into the existing reader and the files, and write nothing by opening", async () => {
    const server = detailsServer();
    renderApp({ server, url: "/sub/preview/library/7" });
    const heading = await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
    expect(heading).toBeTruthy();
    const action = screen.getByRole("link", { name: /^Start reading/ });
    expect(action.getAttribute("href")).toBe("/sub/read/7");
    expect(screen.getByText("A quiet place to begin.")).toBeTruthy();
    const table = screen.getByRole("table", { name: /Files stored for The Quiet Library/ });
    expect(within(table).getByRole("rowheader", { name: "A Book.epub" })).toBeTruthy();
    expect(within(table).getByText("2.0 KB")).toBeTruthy();
    expect(server.requests.filter((request) => request.method !== "GET")).toEqual([]);
  });

  test("an audiobook with a saved place offers Continue listening and says where", async () => {
    const server = detailsServer(detail({ book_type: "audiobook", action: "listen", format_label: "Audiobook", reading_status: "in_progress", progress, progress_label: "Resume at 0:17", reader_url: "/sub/read/7" }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const action = await screen.findByRole("link", { name: /^Continue listening/ });
    expect(action.getAttribute("href")).toBe("/sub/read/7");
    expect(screen.getByText("Resume at 0:17")).toBeTruthy();
  });

  test("a finished book is offered again", async () => {
    renderApp({ server: detailsServer(detail({ reading_status: "finished", progress_label: "Finished" })), url: "/sub/preview/library/7" });
    expect(await screen.findByRole("link", { name: /^Read again/ })).toBeTruthy();
  });

  test("a book without files cannot be opened and says why", async () => {
    renderApp({ server: detailsServer(detail({ availability: "unavailable", files: [], progress_label: "Files unavailable" })), url: "/sub/preview/library/7" });
    await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
    expect(screen.queryByRole("link", { name: /Start reading/ })).toBeNull();
    expect(screen.getByRole("note").textContent).toContain("not available on the server");
    expect(screen.queryByRole("table")).toBeNull();
  });

  test("a deleted book gets a clear way back", async () => {
    const server = standardServer().on("GET", /\/api\/v1\/library\/7$/, () => ({ status: 404, body: { error: "not_found" } }));
    renderApp({ server, url: "/sub/preview/library/7" });
    await screen.findByText("This book is no longer in your library");
    expect(screen.getByRole("link", { name: "Back to the library" }).getAttribute("href")).toBe("/sub/preview/library");
  });

  test("a failing server is retryable", async () => {
    let fail = true;
    const server = standardServer().on("GET", /\/api\/v1\/library\/7$/, () => (fail ? { status: 500, body: { error: "internal" } } : { body: { account: ACCOUNT, publication: detail() } }));
    renderApp({ server, url: "/sub/preview/library/7" });
    await screen.findByText("Your server had a problem", {}, { timeout: 8000 });
    fail = false;
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
  }, 15000);

  test("description is plain text even when it looks like markup", async () => {
    const hostile = "<b>bold</b><img src=x onerror=alert(1)>";
    const { view } = renderApp({ server: detailsServer(detail({ description: hostile })), url: "/sub/preview/library/7" });
    await screen.findByText(hostile);
    expect(view.container.querySelector(".description b, .description img")).toBeNull();
  });

  test("saving the status sends one CSRF-protected account-bound write and shows the result", async () => {
    let current = detail();
    const server = detailsServer(current).on("PUT", /\/api\/v1\/library\/7\/reading_status$/, (request) => {
      current = detail({ reading_status: (request.body as { status: "finished" }).status, progress_label: "Finished" });
      return { body: { account: ACCOUNT, publication: current } };
    });
    renderApp({ server, url: "/sub/preview/library/7", csrf: "csrf-xyz" });
    const user = userEvent.setup();
    const save = await screen.findByRole("button", { name: "Save status" });
    expect((save as HTMLButtonElement).disabled).toBe(true);
    await user.selectOptions(screen.getByLabelText("Reading status"), "finished");
    expect((save as HTMLButtonElement).disabled).toBe(false);
    await user.click(save);
    await waitFor(() => expect(screen.getByRole("status").textContent).toContain("Saved. Your saved place is kept."));
    const writes = server.requests.filter((request) => request.method === "PUT");
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({ path: "/sub/preview/api/v1/library/7/reading_status", body: { status: "finished" } });
    expect(writes[0]?.headers["x-csrf-token"]).toBe("csrf-xyz");
    expect(writes[0]?.headers["x-shelfarr-account"]).toBe(ACCOUNT);
    expect(await screen.findByRole("link", { name: /^Read again/ })).toBeTruthy();
  });

  test("a rejected status keeps the draft and explains", async () => {
    const server = detailsServer().on("PUT", /reading_status$/, () => ({ status: 422, body: { error: "invalid_csrf" } }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByLabelText("Reading status"), "in_progress");
    await user.click(screen.getByRole("button", { name: "Save status" }));
    expect((await screen.findByRole("alert")).textContent).toContain("out of date");
    expect((screen.getByLabelText("Reading status") as HTMLSelectElement).value).toBe("in_progress");
  });

  test("a status write that finds the account changed locks the page and shows nothing of the old account", async () => {
    const server = detailsServer().on("PUT", /reading_status$/, () => ({ status: 401, body: { error: "account_changed" } }));
    renderApp({ server, url: "/sub/preview/library/7" });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByLabelText("Reading status"), "finished");
    await user.click(screen.getByRole("button", { name: "Save status" }));
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    expect(screen.queryByText("The Quiet Library")).toBeNull();
  });

  test("a status response that resolves after the account changed is not applied", async () => {
    const gate = deferred<void>();
    const server = detailsServer().on("PUT", /reading_status$/, async () => {
      await gate.promise;
      return { body: { account: ACCOUNT, publication: detail({ title: "Applied to the wrong account" }) } };
    });
    const { services } = renderApp({ server, url: "/sub/preview/library/7" });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByLabelText("Reading status"), "finished");
    await user.click(screen.getByRole("button", { name: "Save status" }));
    services.guard.lock("account_changed");
    gate.resolve();
    await screen.findByRole("heading", { name: "The signed-in account changed" });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.queryByText("Applied to the wrong account")).toBeNull();
    expect(services.queryClient.getQueryCache().getAll()).toHaveLength(0);
  });

  test("back returns to the library with its filters when the user came from there", async () => {
    const server = detailsServer().on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: { account: ACCOUNT, items: [{ ...detail(), description: undefined, files: undefined }], next_cursor: null } }));
    const { router } = renderApp({ server, url: "/sub/preview/library?type=ebook" });
    const user = userEvent.setup();
    await user.click(await screen.findByRole("link", { name: "The Quiet Library" }));
    await screen.findByRole("heading", { level: 1, name: "The Quiet Library" });
    await user.click(screen.getByRole("button", { name: /Back to the library/ }));
    await screen.findByRole("heading", { level: 1, name: "Library" });
    expect(router.state.location.search).toEqual({ type: "ebook" });
    expect((screen.getByRole("radio", { name: "Ebooks & comics" }) as HTMLInputElement).checked).toBe(true);
  });
});
