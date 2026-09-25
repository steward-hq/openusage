# Synthetic

Shows your Synthetic 5-hour session request allowance and weekly credits from your configured shared limits hub — the same
numbers AI Limits on your phone sees.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Percentage of the 5-hour rolling request limit used, with its reset time |
| Weekly | Percentage of the weekly credit limit used, with its regeneration time |

There is no plan badge and no local usage: Synthetic has no logs or credentials on your Mac, so
the shared hub is the only source.

## Shared limits hub (required)

Synthetic works only through the shared limits hub — the same `~/.openusage/limits-hub.json` the
other hub providers use. Add `"synthetic"` to your config:

```json
{
  "snapshotURL": "https://your-hub.example:4401/snapshot.json",
  "providers": ["synthetic"],
  "resetTimeZone": "UTC"
}
```

Use the same snapshot URL as the phone. `resetTimeZone` is the time zone of the hub's browser, not
your Mac; it is only needed for reset labels that lack an ISO timestamp. If omitted, those reset
times remain unknown. Refresh OpenUsage after changing this file.

- With the hub configured, both meters appear and turn on automatically.
- Without it, Synthetic stays off — nothing on this Mac identifies you as a Synthetic user. If you
  turn it on anyway, OpenUsage explains that the hub isn't configured rather than inventing an
  error.
- Missing values remain unavailable, real zeroes remain zero, and hub failures show a warning.
  Data older than 30 minutes is unavailable until the hub collector updates it.

No Synthetic credentials or local data are sent to the hub by OpenUsage.

## Troubleshooting

- **"Synthetic isn't listed in your shared limits hub"** — the provider is on but the hub config
  doesn't include `"synthetic"`. Edit `~/.openusage/limits-hub.json` and refresh.
- **Shared hub warning** — check Tailscale and the hub collector. Renew the browser session on the
  hub if it reports `needs-session`.
- **Meters show "No usage data"** — the hub published the provider but not both quotas yet. The
  missing meter stays hidden rather than shown at zero.