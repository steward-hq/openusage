# Ollama

Tracks [Ollama Cloud](https://ollama.com) subscription usage — the monthly credit limit and recent spend Ollama
shows on its own settings page.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly | Percentage of your plan's monthly included credit allowance used, with its renewal date |
| Last 4 Weeks | Charges beyond your plan over the last four weeks. $0.00 on a subscription; real amounts for pay-as-you-go and API-key usage |

Your plan (Free, Pro, Max) is shown beside the provider name.

Monthly is always visible and starts pinned to the menu bar. Last 4 Weeks sits behind the
provider's caret — you can move any of them in **Customize**. A $0.00 on that row means no extra charges,
not an idle month: usage inside your plan's allowance is counted by the Monthly meter.

Local models don't count toward the limit; only cloud models do.

## Where credentials come from

Nothing to paste. Ollama creates a signing key at `~/.ollama/id_ed25519` the first time it runs, and
`ollama signin` links that key to your ollama.com account. OpenUsage reads the key, signs each request
with it exactly as the Ollama CLI does, and never sends the key anywhere — only the signature goes out.

Because that key exists whether or not you've signed in, OpenUsage can tell only that Ollama is
installed — not that Ollama Cloud is set up. So on its own the key never switches Ollama on: if you
use Ollama for local models alone, it stays out of your way instead of showing you a sign-in
warning for a product you don't use. The one thing that does enable it is a listing in your
[shared limits hub](#shared-limits-hub-optional) — the hub collector only publishes providers
whose account session it holds. Otherwise, turn it on in **Customize** when you want it.

## Setup

1. Install [Ollama](https://ollama.com/download) and subscribe to a [cloud plan](https://ollama.com/pricing).
2. Sign in:

```bash
ollama signin
```

3. Turn **Ollama** on in **Customize** — unlike most providers, it never enables itself (see above).

Monthly and Last 4 Weeks then appear on the dashboard and Monthly in the menu bar on the next refresh.

## Shared limits hub (optional)

To use the same Ollama Cloud quotas as AI Limits on your phone, add `"ollama"` to
`~/.openusage/limits-hub.json` (see [Muse Code](muse.md#shared-limits-hub-optional) for the
full config shape and freshness rules):

```json
{
  "snapshotURL": "https://your-hub.example:4401/snapshot.json",
  "providers": ["ollama"],
  "resetTimeZone": "UTC"
}
```

Once configured, the Monthly meter comes exclusively from the hub — OpenUsage does not
fall back to ollama.com for it, and no plan badge appears (the hub doesn't publish it). The
Last 4 Weeks spend row still comes from the signed ollama.com API when your local key is available,
because recent activity spend isn't a quota the hub publishes. A hub failure shows a warning with
whatever the spend row can still offer; Ollama listing itself in the hub also turns the provider
on automatically.

## Under the hood

Two ollama.com endpoints, both authenticated with a signature from your local Ollama key:

- `GET https://ollama.com/api/usage` — the session and weekly meters plus recent activity spend.
- `POST https://ollama.com/api/me` — the plan name (best-effort; a failure here doesn't blank the meters).

Each request carries an `Authorization` header of `<public key>:<signature>`, signing the string
`<METHOD>,<request-uri>` where the URI includes a `ts` unix-seconds parameter — the same scheme the
Ollama CLI uses, so a captured header can't be replayed later.

The usage endpoint is undocumented (it backs Ollama's own settings page), so OpenUsage reads it
defensively: `usage` is a fraction (`0.349` → 34.9%) and `cost` is a decimal string; a limit that isn't
in the response is left off the dashboard rather than shown as zero usage. A response with no `limits`
at all is reported as an invalid response.

## Troubleshooting

- **"No Ollama key found"** — Ollama has never run on this Mac. [Install it](https://ollama.com/download)
  and run `ollama signin`.
- **"Not signed in to Ollama Cloud"** — Ollama is installed but the key isn't linked to an account.
  Run `ollama signin`.
- **"Couldn't read ~/.ollama/id_ed25519"** — the key file exists but isn't readable. Check its
  permissions (it should be owned by you, mode `600`).
- **Meters show "No usage data"** — you're signed in, but Ollama returned no limits for the account yet.
  Check your usage at [ollama.com/settings](https://ollama.com/settings).
- **Shared hub warning** — check Tailscale and the hub collector. Renew the browser session on the hub
  if it reports `needs-session`; signing in on this Mac does not update the hub.
