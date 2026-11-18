import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Mutant = { name: string; file: string; old: string; replacement: string; tests: string[] };

const GO_AUTH = ["test/go-auth.test.tsx"];
const GO_CONNECT = ["test/go-connect.test.tsx"];
const READER = ["test/reader.test.ts"];
const PAGES = ["test/pages.test.ts"];

const mutants: Mutant[] = [
  { name: "sign-in: a second submit while one is pending is sent", file: "src/go/SignInPage.tsx", old: "if (submitting.current) return;", replacement: "", tests: GO_AUTH },
  { name: "sign-in: the login token is never refreshed before it expires", file: "src/go/SignInPage.tsx", old: "if (current.current.expiresAt - now() > REFRESH_MARGIN_MS) return current.current.value;", replacement: "if (current.current.expiresAt - now() > REFRESH_MARGIN_MS - 1e12) return current.current.value;", tests: GO_AUTH },
  { name: "sign-in: the password is truncated", file: "src/go/SignInPage.tsx", old: "onSignedIn(await auth.login(username, password, value));", replacement: "onSignedIn(await auth.login(username, password.slice(0, 72), value));", tests: GO_AUTH },
  { name: "sign-in: the failure is not moved into focus", file: "src/go/SignInPage.tsx", old: "if (failure) summary.current?.focus();", replacement: "", tests: GO_AUTH },
  { name: "sign-in: fields are not marked invalid after rejected credentials", file: "src/go/SignInPage.tsx", old: "const invalid = failure?.credentials === true;", replacement: "const invalid = false;", tests: GO_AUTH },
  { name: "sign-in: the password field refuses nothing but pasting is blocked", file: "src/go/SignInPage.tsx", old: 'autoComplete="current-password"', replacement: 'autoComplete="off"', tests: GO_AUTH },
  { name: "sign-out: the session is not revoked", file: "src/go/GoApp.tsx", old: "await auth.logout(account, value);", replacement: "", tests: GO_AUTH },
  { name: "sign-out: a rejected token is not refreshed for the next attempt", file: "src/go/GoApp.tsx", old: 'if (error instanceof ApiError && error.kind === "csrf") await csrf.refresh();', replacement: "", tests: GO_AUTH },
  { name: "consent: a late decision overwrites the screen of another code", file: "src/go/ConnectPage.tsx", old: 'if (issued !== navigation.current) return;\n          deciding.current = false;\n          dispatch({ type: "decided"', replacement: 'deciding.current = false;\n          dispatch({ type: "decided"', tests: GO_CONNECT },
  { name: "mutation: a rejected token is not refreshed", file: "src/api/client.ts", old: 'if (kind === "csrf") this.deps.mutations?.rejected();', replacement: "", tests: GO_AUTH },
  { name: "mutation: the account is not bound to a write", file: "src/api/client.ts", old: "const headers: Record<string, string> = { Accept: \"application/json\", [ACCOUNT_HEADER]: guard.account };", replacement: "const headers: Record<string, string> = { Accept: \"application/json\" };", tests: GO_AUTH.concat(GO_CONNECT) },
  { name: "mutation: the CSRF token is not sent", file: "src/api/client.ts", old: 'if (token) headers["X-CSRF-Token"] = token;', replacement: 'if (token) headers["X-Token"] = token;', tests: GO_AUTH.concat(GO_CONNECT) },
  { name: "consent: an uncertain answer is offered as a fresh decision", file: "src/go/ConnectPage.tsx", old: 'return state.kind === "deciding" ? { kind: "uncertain", code: state.code, grant: state.grant } : state;', replacement: 'return state.kind === "deciding" ? { kind: "decidable", code: state.code, grant: state.grant, notice: null } : state;', tests: GO_CONNECT },
  { name: "consent: a second decision is sent while one is pending", file: "src/go/ConnectPage.tsx", old: 'if (deciding.current || state.kind !== "decidable") return;', replacement: 'if (state.kind !== "decidable" && state.kind !== "deciding") return;', tests: GO_CONNECT },
  { name: "consent: a code of another account is decidable", file: "src/go/ConnectPage.tsx", old: "if (!grant.decidable || grant.client_name === undefined) return null;", replacement: "if (grant.client_name === undefined) return null;", tests: GO_CONNECT },
  { name: "consent: loading the page decides", file: "src/go/ConnectPage.tsx", old: "if (state.kind === \"inspecting\") inspect(state.code);", replacement: "if (state.kind === \"inspecting\") { inspect(state.code); void api.decideConnection(state.code, \"allow\"); }", tests: GO_CONNECT },
  { name: "consent: the permissions are not the offered scopes", file: "src/go/ConnectPage.tsx", old: "{grant.scopes.map((scope) => (", replacement: "{['library:read'].map((scope) => (", tests: GO_CONNECT },
  { name: "consent: the upgrade wording is lost", file: "src/go/ConnectPage.tsx", old: 'const title = grant.upgrade ? "Allow requesting from your app" : "Connect your Shelfarr app";', replacement: 'const title = "Connect your Shelfarr app";', tests: GO_CONNECT },
  { name: "consent: the code is taken from the first value", file: "src/go/ConnectPage.tsx", old: "const last = values[values.length - 1];", replacement: "const last = values[0];", tests: GO_CONNECT },
  { name: "library: dead classic handoffs are shown in Go mode", file: "src/components/Navigation.tsx", old: 'const handoffs = mode === "rails";', replacement: 'const handoffs = mode === "rails" || mode === "go";', tests: GO_AUTH },
  { name: "library: the Rails reader link that would 404 is shown in Go mode", file: "src/components/DetailsPage.tsx", old: 'const readerLink = mode === "go" ? goReaderLink(publication, boot.mount, boot.reader_formats) : publication.reader_url;', replacement: "const readerLink = mode === \"go\" ? (publication.reader_url || goReaderLink(publication, boot.mount, boot.reader_formats)) : publication.reader_url;", tests: GO_AUTH },
  { name: "reader: a PDF is offered to the browser reader", file: "src/reader/links.ts", old: "publication.files.some((file) => formats.includes(file.format))", replacement: "publication.files.some(() => formats.length > 0)", tests: READER.concat(PAGES, GO_AUTH) },
  { name: "reader: a comic is offered to a server that cannot open it", file: "src/reader/links.ts", old: "needed.length > 0 && needed.every((format) => formats.includes(format))", replacement: "needed.length > 0 && formats.length > 0", tests: READER.concat(PAGES) },
  { name: "pages: a turn is dated by when it was shown, not by its input", file: "src/reader/pages.ts", old: "this.reader.locator(position) }, at);", replacement: "this.reader.locator(position) }, this.now());", tests: PAGES },
  { name: "pages: zooming is recorded as reading", file: "src/reader/pages.ts", old: "return step().then(() => this.report());", replacement: "return step().then(() => { this.report(); this.callbacks.moved({ asset_id: this.asset.id, locator: this.reader.locator(this.reader.position) }, this.now()); });", tests: PAGES },
  { name: "pages: page reads carry no account", file: "src/reader/pages.ts", old: "headers.set(ACCOUNT_HEADER, guard.account);", replacement: "headers.delete(ACCOUNT_HEADER);", tests: PAGES },
  { name: "pages: an ended session keeps the reader unlocked", file: "src/reader/pages.ts", old: "        guard.lock(code);\n", replacement: "", tests: PAGES },
  { name: "pages: a zoomed page cannot be panned from the keyboard", file: "src/reader/pages.ts", old: "        stage.tabIndex = 0;\n", replacement: "", tests: PAGES },
  { name: "pages: the saved file is not the one opened", file: "src/reader/ReaderApp.tsx", old: "  if (saved) return saved;\n", replacement: "  if (saved && saved.format === \"never\") return saved;\n", tests: PAGES },
  { name: "reader: a 409 conflict is taken as a saved place", file: "src/api/client.ts", old: "(conflict && options.conflict ? options.conflict : options.schema)", replacement: "options.schema", tests: READER },
  { name: "reader: Retry sends a new mutation instead of the uncertain one", file: "src/reader/progress.ts", old: "    this.held = null;\n    void this.send(request, false);", replacement: "    this.held = null;\n    void this.send({ ...request, client_mutation_id: this.options.uuid() }, false);", tests: READER },
  { name: "reader: the activity time is the upload time", file: "src/reader/progress.ts", old: "void this.send({ ...next.place, observed_at: next.observedAt,", replacement: "void this.send({ ...next.place, observed_at: new Date(this.options.now()).toISOString(),", tests: READER },
  { name: "reader: a later place from another device is overwritten", file: "src/reader/progress.ts", old: "if (!remote || (remoteTime !== null && localTime > remoteTime)) {", replacement: "if (!remote || remoteTime !== null) {", tests: READER },
  { name: "reader: saving continues after the account changed", file: "src/reader/progress.ts", old: "return !this.stopped && this.options.guard.isActive();", replacement: "return !this.stopped;", tests: READER },
  { name: "reader: arrows typed in an editing control turn pages", file: "src/reader/keys.ts", old: "if (!plain(event) || within(event.target, EDITING)) return null;", replacement: "if (!plain(event)) return null;", tests: READER },
  { name: "player: Play after a pause does not rewind", file: "src/reader/audio.ts", old: "const from = this.checkpoints.resume(audio.currentTime);", replacement: "const from = audio.currentTime;", tests: READER },
  { name: "player: a refused play is not shown", file: "src/reader/audio.ts", old: 'problem: error instanceof DOMException && error.name === "NotAllowedError" ? "blocked" : "failed"', replacement: 'problem: null', tests: READER },
  { name: "library: a refused format is shown as a generic server error", file: "src/api/client.ts", old: 'if (code?.startsWith("unsupported_")', replacement: 'if (false && code?.startsWith("unsupported_")', tests: GO_AUTH },
  { name: "boot: an unknown view is accepted", file: "src/contract.ts", old: 'view: z.enum(goViews),', replacement: "view: z.string(),", tests: GO_AUTH },
  { name: "boot: an account in the Go boot block is trusted", file: "src/contract.ts", old: "export const goBootSchema = z.object({", replacement: "export const goBootSchema = z.looseObject({", tests: GO_AUTH },
];

const root = process.argv[2];
if (!root) throw new Error("usage: bun mutate.ts PRIVATE_WEB_COPY");

let survived = 0;
for (const mutant of mutants) {
  const base = mkdtempSync(join(process.env["TMPDIR"] ?? "/var/tmp", "mut-"));
  const work = join(base, "apps", "web");
  try {
    mkdirSync(work, { recursive: true });
    cpSync(join(root, "../../app/javascript"), join(base, "app", "javascript"), { recursive: true });
    for (const entry of readdirSync(root)) if (entry !== "node_modules" && entry !== "e2e") cpSync(join(root, entry), join(work, entry), { recursive: true });
    symlinkSync(join(root, "node_modules"), join(work, "node_modules"));
    const path = join(work, mutant.file);
    const text = readFileSync(path, "utf8");
    if (text.split(mutant.old).length !== 2) throw new Error(`mutation target occurs ${text.split(mutant.old).length - 1} times in ${mutant.file}: ${mutant.old}`);
    writeFileSync(path, text.replace(mutant.old, () => mutant.replacement));
    const typecheck = Bun.spawnSync(["bun", "x", "tsc", "--noEmit"], { cwd: work });
    const compiles = typecheck.exitCode === 0;
    const run = Bun.spawnSync(["bun", "test", ...mutant.tests], { cwd: work, env: { ...process.env, CI: "1" } });
    const output = run.stdout.toString() + run.stderr.toString();
    const assertion = /\(fail\)/.test(output) && /error:|expect\(|Expected|TestingLibraryElementError/.test(output);
    if (!compiles) {
      console.log(`INVALID  ${mutant.name}: the mutant does not typecheck, which proves nothing`);
      survived += 1;
    } else if (run.exitCode === 0 || !assertion) {
      console.log(`SURVIVED ${mutant.name}`);
      survived += 1;
    } else {
      console.log(`detected ${mutant.name}`);
    }
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}
console.log(`${mutants.length - survived}/${mutants.length} web mutants detected by an assertion`);
process.exit(survived === 0 ? 0 : 1);
