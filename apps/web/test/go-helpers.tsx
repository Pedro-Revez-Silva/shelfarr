import { render } from "@testing-library/react";
import { resetFirstPage } from "../src/components/PageHeading";
import type { GoBoot, GoView } from "../src/contract";
import { GoApp } from "../src/go/GoApp";
import { ACCOUNT, FakeServer, page, session, summary, detail } from "./helpers";

export const API = "/preview/api/v1";

export function goBoot(view: GoView = "library"): GoBoot {
  return { version: 1, runtime: "go", view, mount: "/preview", api: API };
}

export function signedOut(token = "login-token", extra: Record<string, unknown> = {}) {
  return { authenticated: false, csrf_token: token, expires_in: 600, sign_in: { available: true, reason: null }, ...extra };
}

export function signedIn(account = ACCOUNT, token = "session-token", expires = 7200) {
  return { authenticated: true, account, csrf_token: token, expires_in: expires };
}

export function libraryServer(bootstrap: () => unknown): FakeServer {
  return new FakeServer()
    .on("GET", /\/auth\/bootstrap$/, () => ({ body: bootstrap() }))
    .on("GET", /\/api\/v1\/session$/, () => ({ body: session() }))
    .on("GET", /\/api\/v1\/continue/, (request) => ({ body: { account: request.headers["x-shelfarr-account"] ?? ACCOUNT, items: [] } }))
    .on("GET", /\/api\/v1\/library(\?|$)/, () => ({ body: page([summary()]) }))
    .on("GET", /\/api\/v1\/library\/7$/, () => ({ body: { account: ACCOUNT, publication: detail() } }));
}

export function renderGo(options: { server: FakeServer; view?: GoView; url?: string }) {
  resetFirstPage();
  window.history.replaceState(null, "", options.url ?? "/preview/library");
  return render(<GoApp boot={goBoot(options.view ?? "library")} fetcher={options.server.fetcher} />);
}

export function error(status: number, code: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  return { status, body: { error: code, ...extra }, headers };
}
