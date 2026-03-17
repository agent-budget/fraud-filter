# agent-trust

A community trust network for agent payment endpoints. Downloads nightly trust scores, provides pre-transaction verification, and accepts anonymous reports of bad service experiences.

## Problem

Agent payments via x402 are irreversible stablecoin transfers. No chargebacks, no dispute networks, no reversals. When an agent pays for a service and gets garbage back, the money is gone.

Today, an agent making an x402 payment has zero information about the service it's about to pay. Is this endpoint reliable? Is this price normal? Has anyone reported problems? No signal at all.

agent-trust provides that signal.

## What It Does

### Downloads trust scores nightly

A trust database (~50KB JSON) is pulled from CDN once per day. It covers every known x402 endpoint with:

- **Trust score** (0-100): Composite score from success rate, report volume, price stability, recency, and age
- **Success rate**: Percentage of successful transactions
- **Price data**: Median, p10, p90 price ranges
- **Warning flags**: Known issues (high failure rate, volatile pricing, new endpoint, etc.)
- **Failure history**: When and what type of failures were reported

### Pre-transaction verification

Before a payment, agent-trust checks its local database and returns a trust assessment:

```json
{
  "endpoint": "https://stockdata.xyz/api/report",
  "known": true,
  "score": 94,
  "success_rate": 0.97,
  "median_price": "0.03",
  "warnings": [],
  "recommendation": "allow"
}
```

Recommendations: `allow` (score 70+), `caution` (score 40-69 or unknown), `block` (score <40).

### Accepts anonymous reports

When the owner flags a bad transaction, agent-trust queues an anonymous signal:

```json
{
  "endpoint_hash": "sha256:a1b2c3d4...",
  "outcome": "post_payment_failure",
  "amount_range": "0.01-0.10",
  "timestamp_bucket": "2026-03-15",
  "reporter_hash": "sha256:install_id_hash"
}
```

No user identity. No transaction details. No wallet address. Just: this endpoint, this outcome class, this rough price range, this day.

## Quick Start

```bash
# Install
clawhub install agent-trust

# Check an endpoint
scripts/check-endpoint.sh https://api.example.com/data

# Start the dashboard
scripts/dashboard.sh start
# → http://127.0.0.1:18921

# Download trust data
scripts/sync-trust-db.sh

# Report a bad experience
scripts/report.sh https://bad-service.xyz/api post_payment_failure 0.50
```

## Integration with agent-budget

agent-trust is a companion to agent-budget. The owner never interacts with agent-trust directly — everything surfaces through agent-budget's dashboard:

- Trust scores appear on transaction rows
- Warnings appear before payments
- The "Report" button triggers agent-trust's reporting flow
- Trust network opt-in is a toggle in settings

### Data flow

```
agent-budget (local, private)          agent-trust (networked, shared)
─────────────────────────────          ─────────────────────────────────
Detects payment about to happen  ───►  Checks local trust DB
                                 ◄───  Returns score + recommendation
Decides: allow / block / ask

Payment completes or fails
Logs transaction locally

Owner clicks "Report"            ───►  Queues anonymous signal
                                 ───►  Sends to api.spendlog.ai/reports

                                       [Overnight on server]
                                       Signals aggregated → trust.json rebuilt
                                       Pushed to Cloudflare CDN

Next day sync                    ◄───  Downloads fresh trust.json
```

## Privacy

- **Download only** (default): Pull scores, send nothing
- **Report only**: Download + send manual reports when owner clicks "Report"
- **Full participation**: Download + manual reports + automatic positive signals

Endpoint URLs are SHA-256 hashed. Only hostnames appear as hints. No wallet addresses, transaction details, or user identity ever leave the local machine.

## Configuration

In `~/.openclaw/openclaw.json` or via the dashboard Settings tab:

```json
{
  "skills": {
    "agent-trust": {
      "enabled": true,
      "config": {
        "trust_db_url": "https://cdn.spendlog.ai/trust.json",
        "report_endpoint": "https://api.spendlog.ai/reports",
        "sync_interval_hours": 24,
        "participate_in_network": false,
        "auto_positive_signals": false
      }
    }
  }
}
```

## Roadmap

- **v0.1** (current): Trust DB download, local lookup, anonymous reporting, dashboard
- **v0.2**: Price crawling — hit known x402 endpoints for 402 responses (free) to build price history without user signals
- **v0.3**: Service directory — query cheapest reliable endpoints for a given data type
- **v0.4**: BBB-style quality reporting — structured feedback beyond binary success/failure
- **v0.5**: Curated blacklist/whitelist feeds for automatic policy enforcement
