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

These views use Hardcover's public data only. Shelfarr does not offer personalized recommendations.

### Connect your Hardcover account

Go to **Profile → Hardcover account** (or **Discover → Following**) and choose one of the options your administrator enabled:

- **Sign in with Hardcover** — you approve read-only access on Hardcover and return to Shelfarr.
- **Sign in with a code** — Shelfarr shows a code; enter it at [hardcover.app/link](https://hardcover.app/link) on any device.
- **Personal API key** (only if enabled) — create a key with `read:me:content read:library read:lists read:catalog` and paste it once. Shelfarr encrypts it and never shows it again.

Shelfarr asks for `read:me:content`, `read:library`, `read:lists`, and `read:catalog`. You can revoke access at any time on Hardcover's *Authorized Apps* page or with **Disconnect** in Shelfarr. Disconnecting deletes the stored tokens, revokes the sign-in on Hardcover, and pauses your Want to Read shelf and your own lists. Reconnecting resumes them. Requests that were already created are kept.

### Preview, then follow

Connecting an account never requests anything. To start, open **Following** and choose **Preview** on your Want to Read shelf or a list — or open a public list or an author from Discover and choose **Preview & follow** / **Follow author**.

The preview loads the entries from Hardcover in the background (up to 1,000; older entries beyond that are treated as already present) and shows each book with its per-format status. Then:

1. Tick the books you want now, or choose **Request every released book in this preview** to request the whole backlog explicitly.
2. Choose the formats (ebook, audiobook).
3. Decide whether books added later should be requested automatically.
4. Choose **Follow and request selected**.

Books you did not select become the *baseline*: they are remembered as already present and are never requested automatically. Later checks only act on what is new:

- **Lists and Want to Read** — books added after the preview. With automatic requests off, they appear under **New** for you to request or dismiss.
- **Authors** — new releases. Books announced for a future date are listed as **Upcoming** and are requested (or offered for review) once they are released. Selecting an upcoming book requests it on release even when automatic requests are off. An old book that Hardcover adds to the catalog later is treated as backlist, not as a new release.

Removing a book from a Hardcover list, unfollowing a list or author, or disconnecting your account never cancels or deletes requests.

### Author catalogs

Hardcover credits editors, translators, narrators, illustrators, and introduction writers in the same place as authors, and its community catalog can contain duplicate or translated records. Shelfarr only lists books the person **wrote**, and hides:

- credits where they were only an editor, translator, narrator, or another non-author role;
- duplicate records of a book already listed, and records Hardcover has merged into another book;
- box sets and compilations;
- records only available in languages this Shelfarr does not request (**Settings → Language & Matching → Enabled Languages**).

The author page and the followed author both say how many records were hidden and why.

### Status and errors

Each followed list or author shows when it was last checked and any problem. Books that could not be requested are listed under **Failed** with the reason; Shelfarr retries them with increasing delays and you can retry manually. **Check now** can be used every few minutes. **Pause** stops all automatic requests for that subscription until you resume.

## For administrators

### Discovery

Discovery uses the instance Hardcover API token in **Settings → Integrations → Hardcover**. Without it, each user's own connection is used for their browsing instead. Results are cached and shared by all users (trending and releases for six hours, lists for up to an hour), so browsing does not multiply API calls.

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
| Automatic Requests per User per Run | 10 | Cap on automatic requests per user per check; the rest stay queued for the next check |

A scheduler runs every 15 minutes, checks subscriptions that are due, moves released upcoming books forward, and retries failed imports after their backoff. List and Want to Read checks only ask Hardcover for entries changed since the previous successful check.

### Rate limits

Hardcover limits each **account** across all of its apps and tokens (5,000 requests a day and 60 per minute on the free plan). Shelfarr tracks the budget per Hardcover account, so a refreshed token keeps the same budget and the instance token shares its owner's budget. Background checks are paced to the per-minute refill rate and stop before the last part of the daily allowance, leaving it for people browsing. When Hardcover answers with a rate limit, Shelfarr waits for the time Hardcover asks for instead of retrying.

Disabling Hardcover in Settings stops discovery, connections, syncs, and imports. Deleting a user removes their Hardcover connection and pauses their subscriptions.

## Data and attribution

Book data, covers, lists, and author information come from Hardcover and are labelled with a link back to Hardcover. Personal data (your shelf and private lists) is only ever read with your own connection and is not shown to other Shelfarr users.
