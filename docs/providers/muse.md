# Muse Code

Shows your Muse Code session and weekly quotas alongside usage from the session logs already
on your Mac. The quota meters come from your configured shared limits hub, or from Meta's authenticated usage dashboard when no hub is configured; the per-day
spend tiles and trend remain measured local activity, with dollars estimated from Meta's
published Muse Spark rates.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Percentage of the current Muse session allowance used, with its reset time |
| Weekly | Percentage of the weekly Muse allowance used, with its reset time |
| Today / Yesterday / Last 30 Days | Local cost and tokens from your Muse sessions |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

There is no plan badge: with no account API, OpenUsage can't tell which Muse plan you're on.

## Shared limits hub (optional)

To use the same Muse quotas as AI Limits on your phone, create `~/.openusage/limits-hub.json`:

```json
{
  "snapshotURL": "https://your-hub.example:4477/snapshot.json",
  "providers": ["muse"],
  "resetTimeZone": "UTC"
}
```

Use the same snapshot URL as the phone. `resetTimeZone` is the time zone of the hub's browser,
not your Mac; it is only needed for reset labels that lack an ISO timestamp. If omitted, those
reset times remain unknown. This hub runs its browser in UTC.

Refresh OpenUsage after changing this file. Once enabled, Muse quotas come exclusively from the
hub. Missing values remain unavailable, real zeroes remain zero, and hub failures show a warning
while local spending and trends continue working. OpenUsage does not fall back to a second scrape.
Data older than 30 minutes is unavailable until the hub collector updates it.

The personal hubs formerly served on ports `4401` and `4410` now use `4477`. Existing configs for
the four known development boxes migrate automatically; custom hosts and paths remain unchanged.

Only Muse opts into this shared client today. Its HTTPS transport, provider selection, configuration,
and freshness checks can be reused when adding other providers; adding a name alone does not migrate
a provider. No Meta credentials or local logs are sent to the hub by OpenUsage.

## Local dashboard access (when no hub is configured)

OpenUsage reuses the browser session at `~/.config/muse/meta_session.json` that Meta Muse Bar
created. It imports only unexpired `dev.meta.ai` cookies into a private, non-persistent WebKit
view, opens `https://dev.meta.ai/usage`, and reads the rendered **Current usage** and **Weekly
limit** values. Cookie values never appear in OpenUsage logs or leave WebKit's private session.
The direct dashboard result is reused for 30 minutes inside the running app, and failed reads are
not retried inside that interval. OpenUsage's five-minute refresh loop can therefore update local
Muse logs without repeatedly scraping Meta. Relaunching the app starts a new direct-dashboard
interval and performs one fresh read.

This is an unofficial integration with Meta's private authenticated web dashboard, not a public
or supported quota API. OpenUsage deliberately does not copy Meta's changing private GraphQL
request identifiers, CSRF fields, or account fields.

If the saved dashboard session is missing, expired, unreadable, or Meta changes the page,
OpenUsage shows **“Muse quota is unavailable. Sign in through Meta Muse Bar and refresh.”** The
local Usage Trend and spend rows still refresh normally.

## Where local usage comes from

Use Muse Code as usual. OpenUsage never asks for a key: it counts a provider as present
when `META_API_KEY` is exported, when `~/.config/muse/auth.json` exists (written by
`muse login` or `muse auth set`), or when Muse session logs exist on disk. The credential
itself is never read for content and never leaves your Mac — spend comes from the logs, not
from the dashboard or any account API.

## The spend tiles

Each assistant step Muse runs appends a `model_completed` event with its token usage to
that session's `session.jsonl`. OpenUsage scans those logs and prices the tokens through
the shared pricing engine: Muse Spark Standard rates ($1.25 per million input tokens,
$4.25 per million output, $0.15 per million cached input tokens), or the discounted
contributor rates ($0.10 / $0.20) when the session's model id carries the `-contributor`
suffix. Reasoning tokens bill as output, matching Meta. Tokens whose model has no known
price still count toward the token totals but carry no dollars, and the tile warns about
the unknown model instead of pricing them at $0.

A period with no recorded local usage reads "No data" rather than a misleading `$0.00`.
No log data leaves your Mac. Subagent transcripts are skipped: their steps are already
mirrored in the parent session's log, so counting both would double-count delegated work.

## Troubleshooting

- **"Muse Code not detected"** — no credential and no session logs were found. Run
  `muse login` and complete at least one Muse session, then refresh.
- **Shared hub warning** — check Tailscale and the hub collector. Renew the browser session on the hub if it reports `needs-session`. Local re-login does not update the hub.
- **"Muse quota is unavailable"** — open Meta Muse Bar to renew its dashboard session, then
  refresh OpenUsage. Your locally scanned trend and spend rows remain available.
- **"Couldn't read Muse Code's auth.json"** — the file exists but is unreadable. Check
  its permissions, or run `muse login` again to rewrite it.
- **Spend tiles show "No data"** — OpenUsage needs session logs at
  `~/.local/share/muse/sessions/` (or `$XDG_DATA_HOME/muse/sessions/`). Run a Muse
  session, then refresh. Logs older than 30 days are outside the window.
- **Unknown-model warning on a tile** — the session used a Muse model id with no known
  price (e.g. a newer release than the pricing feed). Tokens still count; dollars appear
  once the pricing feed learns the model.

## Under the hood

Logs: every `session.jsonl` under the sessions directory, parsed incrementally (only
changed files re-parse). `recorded_at` is microseconds since the epoch; usage buckets map
to non-cached input, cache read, cache write, and output plus reasoning. Exact duplicate
steps (mirrored or copied logs) count once.

Spend tiles and trend: `model_completed` usage priced through the shared engine, with the
Muse Spark entries in the pricing supplement (synced hourly to installed apps, no release
needed). The scan is machine-local, so tiles from two Macs sync by sum like the other
local scanners.

Quota meters: rendered text from `https://dev.meta.ai/usage`, loaded with the local Meta Muse Bar
storage state in a non-persistent WebKit data store. Quotas and reset times describe this Mac's
current dashboard session and are not combined through iCloud Sync.
