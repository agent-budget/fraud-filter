# agent-trust — Technical Architecture

## Overview

agent-trust is an OpenClaw skill that provides community-sourced trust intelligence for x402 payment endpoints. It downloads aggregated trust data from a CDN, provides instant local lookups, and accepts anonymous outcome signals that feed back into the network.

## Architecture

```
~/.openclaw/skills/agent-trust/
├── SKILL.md                    # Agent-facing instructions
├── PROPOSAL.md                 # Design proposal
├── README.md                   # User-facing overview
├── TECHNICAL.md                # This file
├── package.json                # Minimal metadata (zero dependencies)
├── scripts/
│   ├── dashboard.sh            # Start/stop/manage the dashboard server
│   ├── sync-trust-db.sh        # Downloads trust.json from CDN
│   ├── check-endpoint.sh       # Queries local trust DB for an endpoint
│   ├── report.sh               # Queues anonymous signal for submission
│   └── status.sh               # Shows trust DB age, coverage, sync status
├── server/
│   ├── trust-db.js             # Data layer: DB loading, lookup, scoring, config
│   ├── reporter.js             # Signal construction, queue, submission
│   ├── server.js               # HTTP API server (localhost only, no frameworks)
│   └── index.html              # Single-file dashboard UI
├── data/
│   ├── trust.json              # Local copy of trust database (downloaded nightly)
│   ├── pending-reports.jsonl   # Reports queued for submission
│   └── config.json             # Local configuration (generated on first run)
├── references/
│   └── signal-format.md        # Signal schema & score formula documentation
└── test/
    └── test.js                 # Tests covering data layer, reporter, and API
```

## Design Decisions

### Zero dependencies

Like agent-budget, agent-trust uses only Node.js built-in modules. No npm packages. This eliminates supply chain risk and keeps the skill self-contained.

### Localhost-only binding

The dashboard server binds to `127.0.0.1`, never `0.0.0.0`. Security through network isolation — only local processes can access the API.

### Nightly sync, not real-time

Trust scores update daily, not per-transaction. This is intentional:

1. **Privacy**: Prevents the server from learning transaction patterns ("agent X checked endpoint Y at 3:47pm")
2. **Simplicity**: A static JSON file on CDN is simpler than a real-time query API
3. **Sufficiency**: Service quality doesn't change minute-to-minute

### URL hashing

Endpoint URLs are SHA-256 hashed in the trust database and signals. The `url_hint` field contains only the hostname. This prevents the trust database from becoming a directory of every paid API endpoint on the internet.

### Price bucketing

Exact transaction amounts are bucketed into ranges before reporting. A $0.05 transaction becomes `0.01-0.10`. This preserves enough signal for price anomaly detection without revealing exact spending.

### Human-confirmed negatives

Positive signals can be automatic. Negative signals always require human confirmation. This prevents agent bugs, network timeouts, or configuration errors from generating false complaints against good services.

## Data Model

### Trust Database (`trust.json`)

Flat JSON keyed by SHA-256 hash of normalized endpoint URL. See `references/signal-format.md` for full schema.

Key properties per endpoint:
- `report_count`, `success_rate`: Aggregate outcome data
- `median_price_usd`, `price_p10_usd`, `price_p90_usd`: Price distribution
- `first_seen`, `last_success`, `last_failure`: Timeline
- `failure_types`: Breakdown by `post_payment` vs `pre_payment`
- `warnings`: Derived flags (high_failure_rate, volatile_pricing, etc.)
- `score`: Composite trust score 0-100

### Pending Reports (`pending-reports.jsonl`)

Append-only JSONL file. Each line is a signal with status tracking:
- `pending`: Queued, not yet sent
- `sent`: Successfully submitted to reporting endpoint
- `failed`: Submission failed (will retry on next flush)

Sent reports older than 7 days are pruned automatically.

### Configuration (`config.json`)

Generated on first run with a random `install_id` (used only for reporter hash derivation). User-configurable fields:
- `trust_db_url`: CDN URL for trust database
- `report_endpoint`: URL for signal submission
- `sync_interval_hours`: How often to check for updates
- `participate_in_network`: Enable/disable sending signals
- `auto_positive_signals`: Auto-report successful transactions

## Score Calculation

Trust score (0-100) is computed from five weighted factors:

| Factor | Range | Description |
|---|---|---|
| Base | 50 | Starting point for any endpoint with reports |
| Success | -40 to +40 | `(success_rate - 0.5) * 80` |
| Volume | 0 to +10 | `min(10, log10(report_count) * 5)` |
| Recency | -20 to 0 | Penalty for failures within 7 days |
| Stability | -10 to 0 | Penalty for volatile pricing (p90/p10 ratio) |
| Age | -15 to 0 | Penalty for endpoints less than 30 days old |

Full formula documented in `references/signal-format.md`.

### Recommendation mapping

| Score | Recommendation |
|---|---|
| 70-100 | `allow` |
| 40-69 | `caution` |
| 0-39 | `block` |
| unknown | `caution` (with `unknown_endpoint` warning) |

## API Endpoints

All served on `127.0.0.1:18921` (configurable via `AGENT_TRUST_PORT`).

### Read endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/` | Dashboard HTML |
| GET | `/api/check?url=<url>` | Trust assessment for a single endpoint |
| GET | `/api/check-price?url=<url>&price=<usd>` | Price anomaly check |
| GET | `/api/search?q=<query>` | Search endpoints by hostname or hash prefix |
| GET | `/api/endpoints?sort=score&order=desc&limit=50` | List all endpoints (paginated) |
| GET | `/api/status` | DB status, pending reports, participation level |
| GET | `/api/reports` | List pending reports |
| GET | `/api/config` | Current configuration (install_id excluded) |

### Write endpoints

| Method | Path | Description |
|---|---|---|
| POST | `/api/reports` | Queue a new anonymous report |
| POST | `/api/reports/flush` | Submit all pending reports to server |
| POST | `/api/reports/prune` | Remove sent reports older than 7 days |
| POST | `/api/config` | Update configuration |

## Security & Privacy

### What agent-trust NEVER sends

- Individual transaction details (exact amounts, timestamps, services, sessions)
- Wallet addresses or balances
- User identity or API keys
- Agent-budget's transaction log
- Full endpoint URLs (only SHA-256 hashes)

### What agent-trust sends (only with opt-in)

- Anonymous outcome signals (success/failure + bucketed price range + day)
- Manual reports (human-confirmed, same anonymous format)

### What agent-trust downloads

- `trust.json` from CDN (public, same file for everyone)
- No cookies, no tracking, no user-specific content

### Reporter privacy

- `reporter_hash` is a one-way hash of the installation ID
- The installation ID is generated locally and never sent to the server
- Deduplication uses the hash: one report per endpoint per installation per day

### File permissions

All data files written with mode `0o600` (owner read/write only).

## Testing

Run tests with:

```bash
npm test
# or
node --test test/test.js
```

Tests cover:
- **trust-db**: URL normalization, hashing, score computation, warning derivation, endpoint lookup, price anomaly detection, configuration, search
- **reporter**: Signal construction, queueing, deduplication, pending status, pruning
- **server API**: Endpoint check, search, report submission, configuration, status

All tests use temporary directories and clean up after themselves.

## Server-Side Components

Hosted on the spendlog.ai droplet (Hetzner + Cloudflare):

### Reporting endpoint

`POST https://api.spendlog.ai/reports` — Accepts anonymous signals. Validates format, checks rate limits (max 100 signals per reporter_hash per day), appends to processing queue.

### Aggregation pipeline

Runs nightly:
1. Read all signals from queue
2. Deduplicate (same reporter + endpoint + day = one signal)
3. Recompute per-endpoint stats: report count, success rate, price distribution, failure types, score, warnings
4. Generate new `trust.json`
5. Push to Cloudflare CDN
6. Archive processed signals

### CDN delivery

`GET https://cdn.spendlog.ai/trust.json` — Served from Cloudflare edge. Cache TTL: 1 hour. Clients check daily by default.
