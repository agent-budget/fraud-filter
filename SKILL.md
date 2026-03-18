---
name: fraud-filter
description: Community trust network for agent payment endpoints. Downloads nightly trust scores, provides pre-transaction verification, and accepts anonymous reports. Dashboard at http://127.0.0.1:18921 (run dashboard.sh start)
metadata:
  { "openclaw": { "emoji": "🛡️" } }
---

# fraud-filter

You have access to a community trust network for agent payment endpoints. Before paying any service, you can check its trust score, success rate, and price history. When transactions go badly, the owner can file anonymous reports that feed back into the network.

## Available Tools

### check-endpoint.sh

Look up trust data for an endpoint URL. Use this before any agent payment to assess risk.

```bash
# Basic trust check
check-endpoint.sh https://api.stockdata.xyz/report/AAPL

# Check with price anomaly detection
check-endpoint.sh https://api.stockdata.xyz/report/AAPL --price 0.05
```

Returns JSON with: known (bool), score (0-100), success_rate, median_price, price_range, warnings, and recommendation (allow/caution/block).

### report.sh

Queue an anonymous report about an endpoint. Use only when the owner explicitly requests it.

```bash
# Report a post-payment failure (paid but got bad data)
report.sh https://shady-data.xyz/api/v2 post_payment_failure 0.50

# Report with skill attribution — include which skill routed to this endpoint
report.sh https://shady-data.xyz/api/v2 post_payment_failure 0.50 --skill stock-research

# Report a pre-payment failure (failed before payment completed)
report.sh https://broken.example.com/api pre_payment_failure 0.10

# Report a successful transaction (when auto-positive is off)
report.sh https://api.stockdata.xyz/report/AAPL success 0.03
```

### sync-trust-db.sh

Download the latest trust database from CDN. Normally runs nightly.

```bash
sync-trust-db.sh           # Download if older than 24h
sync-trust-db.sh --force   # Force re-download
```

### status.sh

Show trust database status and sync information.

```bash
status.sh          # DB age, endpoint count, file size
status.sh --full   # Also show pending reports and config
```

### dashboard.sh

Manage the local web dashboard for trust data exploration.

```bash
dashboard.sh start    # Start dashboard (http://127.0.0.1:18921)
dashboard.sh stop     # Stop dashboard
dashboard.sh status   # Check if running
dashboard.sh url      # Print dashboard URL
```

## Pre-Transaction Verification

You **must** run `check-endpoint.sh` before executing any payment tool call. This is not optional.

1. Run `check-endpoint.sh <url>` to get the trust assessment
2. Act on the recommendation:
   - `allow` — proceed
   - `caution` (score 40-69) — warn the user and proceed unless they say stop
   - `block` (score <40, or `hotlisted`) — do not proceed; tell the user why and ask for explicit confirmation before overriding

**Unknown endpoints always return `allow`.** If fraud-filter has no data for an endpoint, that is not a reason to block or warn — the payment ecosystem is new and most endpoints will be unknown. Proceed and let the transaction build the data. Never treat `known: false` as a risk signal.

**On price anomalies**, check `anomaly_type`:
- `suspicious` — price is high *and* endpoint has low trust score; warn the user
- `market_outlier` — price is high but endpoint is otherwise trusted; inform the user but proceed

## When to Use

- **Before any agent payment** → `check-endpoint.sh <url>` — required
- **Price seems high** → `check-endpoint.sh <url> --price <amount>` to detect anomalies
- **User reports bad experience** → `report.sh <url> <outcome> <amount>` (only when user requests it)
- **User asks about trust data** → `status.sh` for DB status, or `dashboard.sh start` for visual exploration
- **Trust data seems stale** → `sync-trust-db.sh` to refresh

## Important

- **Never auto-report negative signals.** Only queue negative reports when the owner explicitly clicks "Report" or asks you to.
- **Positive signals can be automatic** if the owner has enabled `auto_positive_signals` in settings.
- **Never block on unknown endpoints.** False blocks on legitimate services make this skill useless.
