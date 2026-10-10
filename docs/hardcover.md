# Hardcover discovery, reading lists, and authors

Shelfarr uses [Hardcover](https://hardcover.app) for three related features:

- **Discover** — browse trending books, recent and upcoming releases, popular books by genre, public lists, and author catalogs, then request books through the normal request form.
- **Reading lists** — connect your own Hardcover account, preview your *Want to Read* shelf or one of your lists, pick what to request, and optionally request books you add later.
- **Authors** — follow an author, choose books from their backlist, and optionally request new releases when they come out.

Shelfarr only *reads* from Hardcover. It never changes your Hardcover library, lists, or ratings.

Every book keeps its stable Hardcover identity (`hardcover:<book id>`), so a book requested from Discover, a list, an author, or Search is the same Shelfarr book. Requests are created through the same path as the request form: per-format duplicate checks, approvals, notifications, and the search queue all behave as usual.

## For users

### Discover

Open **Discover** in the navigation bar.

| Tab | What it shows |
|-----|---------------|
| Books → Trending | Books most read on Hardcover this week, month, three months, or year |
| Books → New releases | Released in the last 90 days, most-saved first |
| Books → Coming soon | Releasing in the next six months, most-anticipated first |
| Books → By genre | Popular books for a genre (Hardcover genre search) |
| Lists | Popular public lists, or a search across public lists |
| Authors | Search authors and open their catalog |
| Following | Your Hardcover shelves and lists, and everything you follow |

Each book shows whether its ebook and audiobook are already in the library or requested. Ownership is tracked per format: owning the ebook does not hide the audiobook request.

These views use Hardcover's public data only, and the results are shared by every Shelfarr user. A private or followers-only list is never shown in Discover, not even to its owner: open it from **Following** instead (see below). Shelfarr does not offer personalized recommendations.

### Connect your Hardcover account

Go to **Profile → Hardcover account** (or **Discover → Following**) and choose one of the options your administrator enabled:

- **Sign in with Hardcover** — you approve read-only access on Hardcover and return to Shelfarr.
- **Sign in with a code** — Shelfarr shows a code; enter it at [hardcover.app/link](https://hardcover.app/link) on any device.
- **Personal API key** (only if enabled) — create a key with `read:me:content read:library read:lists read:catalog` and paste it once. Shelfarr encrypts it and never shows it again.

Shelfarr asks for `read:me:content`, `read:library`, `read:lists`, and `read:catalog`. You can revoke access at any time on Hardcover's *Authorized Apps* page or with **Disconnect** in Shelfarr. Disconnecting deletes the stored tokens, revokes the sign-in on Hardcover, and pauses your Want to Read shelf and your private lists; anything still waiting to be requested from them waits too. Requests that were already created are kept.

Your Want to Read shelf and private lists stay tied to the Hardcover account you previewed them with:

- **Reconnecting the same account** resumes them where they left off.
- **Connecting a different account** (directly, or after disconnecting) never carries the old account's books over. Want to Read starts a new preview of the new account's shelf, with automatic requests off, and nothing is requested until you confirm it. Private lists that belong to the other account stay paused until that account is connected again.

### Preview, then follow

Connecting an account never requests anything. To start, open **Following** and choose **Preview** on your Want to Read shelf or one of your lists (public or private) — or open a public list or an author from Discover and choose **Preview & follow** / **Follow author**. A private or followers-only list can only be followed by its owner and is only ever read with the owner's own connection; you cannot follow someone else's private list.

The preview loads the entries from Hardcover in the background (up to 1,000; for lists and shelves the most recently added, and older entries beyond that are treated as already present; for authors the newest and upcoming releases) and shows each book with its per-format status. Then:

1. Tick the books you want now, or choose **Request every released book in this preview** to request the whole backlog explicitly.
2. Choose the formats (ebook, audiobook).
3. Decide whether books added later should be requested automatically.
4. Choose **Follow and request selected**.

Books you did not select become the *baseline*: they are remembered as already present and are never requested automatically. Later checks only act on what is new:

- **Lists and Want to Read** — books added after the preview. With automatic requests off, they appear under **New** for you to request or dismiss. An unreleased book that was already on the list or shelf when you previewed it is part of the baseline: if you did not select it, it is listed as **Not requested** once it comes out and is never requested automatically. For Want to Read, automatic requests require a newly created Hardcover library entry. Moving an older entry from another shelf or editing its notes, rating, or privacy does not automatically request it; you can select it yourself. Hardcover's last-update date cannot distinguish those changes.
- **Authors** — new releases. Books announced for a future date are listed as **Upcoming** and are requested (or offered for review) once they are released, because following an author means watching for their next books. An old book that Hardcover adds to the catalog later is treated as backlist, not as a new release. A book that first appears without a release date is listed as **Not requested** until Hardcover adds one: a recent date makes it a new release, an old date keeps it backlist.

If a release is postponed before Shelfarr requested it, the book goes back to **Upcoming** with the formats you chose and is requested once the new date arrives. Requests that already exist are kept.

Selecting an upcoming book in any preview requests it on release, even when automatic requests are off.

Each check of a list or shelf reads only what changed since the previous complete check. If more changed than one check reads (500 entries, for example after a long outage), the subscription shows **Catching up** and continues a minute later from where it stopped until every change has been read; nothing is skipped or read twice.

Removing a book from a Hardcover list, unfollowing a list or author, or disconnecting your account never cancels or deletes requests.

### Author catalogs

Hardcover credits editors, translators, narrators, illustrators, and introduction writers in the same place as authors, and its community catalog can contain duplicate or translated records. Shelfarr only lists books the person **wrote**, and hides:

- credits where they were only an editor, translator, narrator, or another non-author role;
- duplicate records of a book already listed, and records Hardcover has merged into another book;
- box sets and compilations;
- records only available in languages this Shelfarr does not request (**Settings → Language & Matching → Enabled Languages**).

The author page and the followed author both say how many records were hidden and why.

Hardcover lists an author's records newest release first, so every check reads the newest and upcoming books, including for authors with very long catalogs. The author page and each check read up to 1,000 records that way (the Discover author page up to 300). When a followed author has more, each check also reads 200 of the older records in turn and starts over after the last one, so older books are added to the list and kept up to date over the following checks. Older books found this way are backlist and are never requested automatically.

### Status and errors

Each followed list or author shows when it was last checked and any problem. Books that could not be requested are listed under **Failed** with the reason; Shelfarr retries them with increasing delays and you can retry manually. **Check now** can be used every few minutes. **Pause** stops all automatic requests for that subscription until you resume, including books already queued: a request being created at that moment finishes, the rest wait.

Each format of a book is requested once. When a book's ebook is requested but its audiobook waits for the next check (because of the automatic request limit) or fails, later checks and retries only request the audiobook: what happens to the ebook from then on is up to its own request, which you can retry or cancel from **Requests**. Selecting the book again also leaves formats it already requested to their requests.

Turning **automatic requests off** stops the automatic requests that were still waiting, including formats waiting for the limit: those books move to **New** with their formats, for you to select or dismiss. Books under **Failed** stay there but are no longer retried by themselves; **Retry** still requests them. Books you selected are still requested, and existing requests are kept. Turning automatic requests on again applies to books added from then on. Older list and Want to Read additions stay for review, even if Shelfarr first sees them after an outage or they are released later. Entries without an addition date also wait for your selection. Saving other settings while automatic requests remain on does not move that starting point. Author follows continue to watch their future releases.

## For administrators

### Discovery

Discovery uses the instance Hardcover API token in **Settings → Integrations → Hardcover**. Without it, each user's own connection is used for their browsing instead. Results are cached and shared by all users (trending and releases for six hours, lists for up to an hour), so browsing does not multiply API calls. Because they are shared, Discover asks Hardcover only for public lists, whichever token it uses, so a private list owned by the instance token's account is never shown to other users. Private lists and Want to Read shelves are only read with their owner's own connection.

### Let users connect their accounts

Shelfarr is self-hosted, so it does not ship a shared Hardcover client. Register your own at [hardcover.app/account/developer-apps/new](https://hardcover.app/account/developer-apps/new) and allow the scopes `read:me:content read:library read:lists read:catalog`.

**If Shelfarr has an HTTPS address:**

1. Choose **Web app (server-side)**.
2. Register the redirect URI shown in **Settings → Integrations → Hardcover** (by default your Shelfarr address followed by `/hardcover/connection/callback`). Hardcover matches it exactly. If Shelfarr is behind a proxy that does not forward its public scheme and host, set **Hardcover OAuth Redirect URI** to the public address.
3. Enter the **client ID** and **client secret**.

**If Shelfarr has no HTTPS address** (for example a LAN install):

1. Choose **Mobile, desktop, or CLI** and turn on **Device Authorization Grant**.
2. Enter the **client ID** and leave the client secret blank.
3. Enable **Allow Sign-in With a Code**.

The client ID, secret, and redirect URI can also be set with `SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_ID`, `SHELFARR_SETTING_HARDCOVER_OAUTH_CLIENT_SECRET`, and `SHELFARR_SETTING_HARDCOVER_OAUTH_REDIRECT_URI`.

The sign-in uses the authorization code flow with PKCE (S256), a single-use state bound to the user's session, and Hardcover's issuer check. Access and refresh tokens are encrypted with Active Record encryption, filtered from logs, used only on the server, and rotated as Hardcover requires.

**Allow Personal API Keys** lets users paste a Hardcover API key instead of signing in. Hardcover recommends OAuth for apps used by other people, so this is off by default; enable it only where users trust the administrator.

### Automation settings

| Setting | Default | Meaning |
|---------|---------|---------|
| Reading List Sync Interval (hours) | 6 | How often followed lists, shelves, and authors are checked (1–168) |
| Automatic Requests per User per Run | 10 | Cap on automatic requests per user in each sync interval, counting each format separately and across all of the user's lists, shelves, and authors. The rest stay queued, in order, for the next interval. Books a user selects themselves are not limited, and formats already in Shelfarr do not count |

A scheduler runs every 15 minutes, checks subscriptions that are due, moves released upcoming books forward, and retries failed imports after their backoff. List and Want to Read checks only ask Hardcover for entries changed since the previous successful check.

### Rate limits

Hardcover limits each **account** across all of its apps and tokens (on the free plan: 5,000 requests a day, and a burst of 10 that refills at 60 per minute). Shelfarr tracks the budget per Hardcover account, so a refreshed token keeps the same budget and the instance token shares its owner's budget. Background checks send at most one request every 1.1 seconds per account, just under the refill rate: several checks for the same account take turns instead of sending together, and they stop before the last 10% of the daily allowance (at least 100 requests), leaving it for people browsing. A short cooldown after the burst is used up is waited out; when Hardcover asks for a longer wait, Shelfarr waits for that time instead of retrying.

Disabling Hardcover in Settings stops discovery, connections, syncs, and imports. Deleting a user removes their Hardcover connection and pauses their subscriptions.

## Data and attribution

Book data, covers, lists, and author information come from Hardcover and are labelled with a link back to Hardcover. Personal data (your shelf and private lists) is only ever read with your own connection and is not shown to other Shelfarr users.
