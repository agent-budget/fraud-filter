---
name: fraud-filter
description: Transaction outcome report network for agent payment endpoints. Downloads nightly satisfaction scores, provides pre-transaction verification, and submits anonymous outcome reports. Dashboard at http://127.0.0.1:18921 (run dashboard.sh start)
metadata:
  { "openclaw": { "emoji": "🛡️" } }
---

# fraud-filter

You have access to a community transaction outcome report network for agent payment endpoints. Before paying any service, you can check its satisfaction score, success rate, and price history. After transactions, you report outcomes back to the network — automatically for clear failures, with human notification either way.

## Available Tools

### check-endpoint.sh

Look up outcome report data for an endpoint URL. Use this before any agent payment to assess risk.

```bash
# Basic check
check-endpoint.sh https://api.stockdata.xyz/report/AAPL

# Check with price anomaly detection
check-endpoint.sh https://api.stockdata.xyz/report/AAPL --price 0.05
```

Returns JSON with: known (bool), score (0-100), success_rate, median_price, price_range, warnings, and recommendation (allow/caution/block).

### report.sh

Queue an anonymous transaction outcome report. See post-transaction workflow below.

```bash
# Report a post-payment failure (paid but received nothing or bad data)
report.sh https://shady-data.xyz/api/v2 post_payment_failure 0.50

# Report with skill attribution
report.sh https://shady-data.xyz/api/v2 post_payment_failure 0.50 --skill stock-research

# Report a pre-payment failure (failed before payment completed)
report.sh https://broken.example.com/api pre_payment_failure 0.10

# Report a successful transaction (when auto-positive is off)
report.sh https://api.stockdata.xyz/report/AAPL success 0.03
```

### sync-trust-db.sh

Download the latest outcome report database from CDN. Normally runs nightly.

```bash
sync-trust-db.sh           # Download if older than 24h
sync-trust-db.sh --force   # Force re-download
```

### status.sh

Show database status and sync information.

```bash
status.sh          # DB age, endpoint count, file size
status.sh --full   # Also show pending reports and config
```

### dashboard.sh

Manage the local web dashboard for outcome data exploration.

```bash
dashboard.sh start    # Start dashboard (http://127.0.0.1:18921)
dashboard.sh stop     # Stop dashboard
dashboard.sh status   # Check if running
dashboard.sh url      # Print dashboard URL
```

## Pre-Transaction Verification

You **must** run `check-endpoint.sh` before executing any payment tool call. This is not optional.

1. Run `check-endpoint.sh <url>` to get the assessment
2. Act on the recommendation:
   - `allow` — proceed
   - `caution` (score 40-69) — warn the user and proceed unless they say stop
   - `block` (score <40, or `hotlisted`) — do not proceed; tell the user why and ask for explicit confirmation before overriding

**Unknown endpoints always return `allow`.** If fraud-filter has no data for an endpoint, that is not a reason to block or warn — the payment ecosystem is new and most endpoints will be unknown. Proceed and let the transaction build the data. Never treat `known: false` as a risk signal.

**On price anomalies**, check `anomaly_type`:
- `suspicious` — price is high *and* endpoint has low satisfaction score; warn the user
- `market_outlier` — price is high but endpoint is otherwise trusted; inform the user but proceed

## Post-Transaction Reporting

After every transaction completes, submit an outcome report. This is how the network stays useful — the community primarily reports negative outcomes, so your reports matter.

**post_payment_failure** (paid, but received nothing or bad data):
- Submit automatically without waiting for human confirmation
- Notify the user: "I submitted an anonymous outcome report for `<hostname>` — paid but received a poor result."

**pre_payment_failure** (failed before payment completed):
- Ask the user before reporting: "The transaction failed before payment. Should I report this to fraud-filter?"
- Technical errors (timeouts, DNS failures) may not reflect the endpoint's quality — human judgment applies here.

**success**:
- Submit automatically if `auto_positive_signals` is enabled in settings
- Otherwise skip unless the user requests it

## Reading the Data Directly

The outcome report database is a flat JSON file at `data/trust.json`. You can read it directly and reason over it yourself — there is no query API because you don't need one. Use this when the user asks questions like "which endpoints have I transacted with most?" or "show me everything flagged as caution" — just read the file and answer.

## When to Use

- **Before any agent payment** → `check-endpoint.sh <url>` — required
- **Price seems high** → `check-endpoint.sh <url> --price <amount>` to detect anomalies
- **Transaction completed with poor outcome** → `report.sh <url> post_payment_failure <amount>` — automatic, notify user
- **Transaction failed before payment** → ask user before reporting
- **User asks about outcome data** → `status.sh` for DB status, read `data/trust.json` directly for deeper questions, or `dashboard.sh start` for visual exploration
- **Trust data seems stale** → `sync-trust-db.sh` to refresh

## Important

- **Auto-report post-payment failures.** The community needs this signal and waiting for human confirmation means it never gets submitted in unattended runs.
- **Always notify the user when auto-reporting.** One line is enough: what endpoint, what outcome, that it was anonymous.
- **Positive signals can be automatic** if the owner has enabled `auto_positive_signals` in settings.
- **Never block on unknown endpoints.** False blocks on legitimate services make this skill useless.
