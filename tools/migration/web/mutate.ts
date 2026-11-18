import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Mutant = { name: string; file: string; old: string; replacement: string; tests: string[] };

const GO_AUTH = ["test/go-auth.test.tsx"];
const GO_CONNECT = ["test/go-connect.test.tsx"];
const READER = ["test/reader.test.ts"];
const PAGES = ["test/pages.test.ts"];
const GO_ACCOUNT = ["test/go-account.test.tsx"];

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
  { name: "pages: a turn is dated by when it was shown, not by its input", file: "src/reader/pages.ts", old: "this.reader.locator(page) }, at);", replacement: "this.reader.locator(page) }, Math.max(at, this.now()));", tests: PAGES },
  { name: "pages: an adopted place keeps the turn still drawing", file: "src/reader/pages.ts", old: "  forgetTurns(): void {\n    this.turnAt = null;\n", replacement: "  forgetTurns(): void {\n", tests: PAGES },
  { name: "pages: returning to the saved page records it again", file: "src/reader/pages.ts", old: "if (page === this.placed || at === null) return;", replacement: "if (at === null) return;", tests: PAGES },
  { name: "pages: a turn that never showed its page leaves the session unchecked", file: "src/reader/pages.ts", old: "if (this.active && this.painted !== target) this.callbacks.unsure();", replacement: "if (this.active && this.painted !== target && target < 0) this.callbacks.unsure();", tests: PAGES },
  { name: "pages: turns are judged by the reader's reports instead of its paints", file: "src/reader/pages.ts", old: "    this.paintWatch.observe(element, { attributes: true, attributeFilter: [\"data-page\", \"data-zoom\"] });\n", replacement: "", tests: PAGES },
  { name: "pages: zooming is recorded as reading", file: "src/reader/pages.ts", old: "return step().then(() => this.report());", replacement: "return step().then(() => { this.report(); this.callbacks.moved({ asset_id: this.asset.id, locator: this.reader.locator(this.reader.position) }, this.now()); });", tests: PAGES },
  { name: "pages: page reads carry no account", file: "src/reader/pages.ts", old: "headers.set(ACCOUNT_HEADER, guard.account);", replacement: "headers.delete(ACCOUNT_HEADER);", tests: PAGES },
  { name: "pages: an ended session keeps the reader unlocked", file: "src/reader/pages.ts", old: "        guard.lock(code);\n", replacement: "", tests: PAGES },
  { name: "pages: a zoomed page cannot be panned from the keyboard", file: "src/reader/pages.ts", old: "        stage.tabIndex = 0;\n", replacement: "", tests: PAGES },
  { name: "pages: the saved file is not the one opened", file: "src/reader/ReaderApp.tsx", old: "  if (saved) return saved;\n", replacement: "  if (saved && saved.format === \"never\") return saved;\n", tests: PAGES },
  { name: "reader: a 409 conflict is taken as a saved place", file: "src/api/client.ts", old: "conflict && options.conflict ? options.conflict : rejected && options.rejection", replacement: "rejected && options.rejection", tests: READER },
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
  { name: "account: a second password change is sent while one is pending", file: "src/components/AccountPage.tsx", old: "    if (submitting.current) return;\n", replacement: "", tests: GO_ACCOUNT },
  { name: "account: a second name save is sent while one is pending", file: "src/components/AccountPage.tsx", old: "    if (saving.current) return;\n", replacement: "", tests: GO_ACCOUNT },
  { name: "account: the password fields keep their values after a change", file: "src/components/AccountPage.tsx", old: "        element.reset();\n", replacement: "", tests: GO_ACCOUNT },
  { name: "account: a mismatched confirmation is sent", file: "src/components/AccountPage.tsx", old: '    if (change.password !== change.password_confirmation) missing["password_confirmation"] = ["doesn\'t match Password"];\n', replacement: "", tests: GO_ACCOUNT },
  { name: "account: a conflict keeps the stale current password", file: "src/components/AccountPage.tsx", old: '          field.value = "";\n', replacement: "", tests: GO_ACCOUNT },
  { name: "account: password managers are not told which account changes", file: "src/components/AccountPage.tsx", old: '<input type="text" name="username" autoComplete="username"', replacement: '<input type="text" name="username" autoComplete="off"', tests: GO_ACCOUNT },
  { name: "account: the new password is offered as the current one", file: "src/components/AccountPage.tsx", old: 'autoComplete="new-password" enterKeyHint="next"', replacement: 'autoComplete="current-password" enterKeyHint="next"', tests: GO_ACCOUNT },
  { name: "account: a refused field is not focused", file: "src/components/accountFields.ts", old: "if (control instanceof HTMLInputElement) control.focus();", replacement: "if (control instanceof HTMLInputElement) control.blur();", tests: GO_ACCOUNT },
  { name: "account: a refused field is not described by its error", file: "src/components/AccountPage.tsx", old: '"aria-describedby": describedBy(hint ?? false, invalid && ids.errors[field]),', replacement: '"aria-describedby": describedBy(hint ?? false),', tests: GO_ACCOUNT },
  { name: "account: an uncertain password answer says nothing changed", file: "src/components/accountFields.ts", old: '    case "network":\n', replacement: "", tests: GO_ACCOUNT },
  { name: "account: a saved name is not shown in the header", file: "src/queries.ts", old: 'if (answer.kind === "saved") show(answer.profile);', replacement: 'if (answer.kind === "saved" && answer.profile.name === "") show(answer.profile);', tests: GO_ACCOUNT },
  { name: "account: a field rejection is read as a server failure", file: "src/api/client.ts", old: "const rejected = options.rejection !== undefined && response.status === 422 && options.rejection.safeParse(payload).success;", replacement: "const rejected = false;", tests: GO_ACCOUNT },
  { name: "account: a profile of another account is accepted", file: "src/contract.ts", old: '.refine((envelope) => envelope.profile.id === envelope.account, "The profile belongs to another account")', replacement: "", tests: GO_ACCOUNT },
  { name: "account: the classic preview serves the Go account page", file: "src/components/AccountPage.tsx", old: 'if (mode !== "go") {', replacement: 'if (mode !== "go" && mode.length === 0) {', tests: GO_ACCOUNT },
  { name: "account: the Go navigation has no Account link", file: "src/components/Navigation.tsx", old: "{handoffs ? null : (", replacement: "{true ? null : (", tests: GO_ACCOUNT.concat(GO_AUTH) },
  { name: "account: a session check that finds this browser no longer allowed keeps the page", file: "src/services.tsx", old: 'if (error.kind === "account_changed" || error.kind === "not_found") return "account_changed";', replacement: 'if (error.kind === "account_changed") return "account_changed";', tests: GO_ACCOUNT },
  { name: "account: a superseded session check locks the page", file: "src/services.tsx", old: "if (lost && generation === guard.generation) guard.lock(lost);", replacement: "if (lost) guard.lock(lost);", tests: GO_ACCOUNT },
  { name: "account: a superseded session check locks inside the client", file: "src/api/client.ts", old: 'if (!verifying && (kind === "signed_out" || kind === "account_changed"))', replacement: 'if (verifying === verifying && (kind === "signed_out" || kind === "account_changed"))', tests: GO_ACCOUNT },
  { name: "account: a repeated refusal is not announced again", file: "src/components/AccountPage.tsx", old: "<p key={outcome.serial} className=", replacement: "<p className=", tests: GO_ACCOUNT },
  { name: "account: a name answer replaces text typed after the submit", file: "src/components/AccountPage.tsx", old: "const current = edits.current === revision;", replacement: "const current = edits.current === revision || true;", tests: GO_ACCOUNT },
  { name: "account: an unreadable success says nothing changed", file: "src/components/accountFields.ts", old: "error.status !== null && error.status >= 400 ? ", replacement: "error.status !== null || error.status === null ? ", tests: GO_ACCOUNT },
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
