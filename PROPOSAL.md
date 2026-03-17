# agent-trust

A community trust network for agent payment endpoints. Downloads nightly trust scores, provides pre-transaction verification, and accepts anonymous reports of bad service experiences.

---

## Problem

Agent payments via x402 are irreversible stablecoin transfers. There are no chargebacks, no dispute networks, no reversals. When an agent pays for a service and gets garbage back, the money is gone.

This means the value of "check before you pay" is fundamentally higher than in traditional commerce. But today, an agent making an x402 payment has zero information about the service it's about to pay. Is this endpoint reliable? Is this price normal? Has anyone reported problems? No signal at all.

agent-trust provides that signal.

---

## What It Does

### Downloads trust scores nightly

A trust database (~50KB JSON) is pulled from Cloudflare CDN once per day. It covers every known x402 endpoint with:

- **Report count**: How many agents have interacted with this endpoint
- **Success rate**: Percentage of successful transactions
- **Median price**: What agents typically pay
- **Price range**: Normal min/max observed
- **Last failure**: When the most recent negative report was filed
- **Warning flags**: Known issues (e.g., "price spike detected", "new endpoint — limited data")

The database is checked locally. No network call at transaction time. Instant lookup.

### Pre-transaction verification

When agent-budget (the companion skill) detects a payment is about to happen via the `before_tool_call` hook, it asks agent-trust: "what do you know about this endpoint?"

agent-trust checks its local trust database and returns a trust assessment:

```json
{
  "endpoint": "https://stockdata.xyz/api/report",
  "known": true,
  "report_count": 347,
  "success_rate": 0.97,
  "median_price": "0.03",
  "price_range": { "p10": "0.02", "p90": "0.05" },
  "last_failure": "2026-03-14T08:22:00Z",
  "warnings": [],
  "recommendation": "allow"
}
```

Or for a suspicious endpoint:

```json
{
  "endpoint": "https://shady-data.xyz/api/v2",
  "known": true,
  "report_count": 12,
  "success_rate": 0.42,
  "median_price": "0.50",
  "price_range": { "p10": "0.05", "p90": "2.00" },
  "last_failure": "2026-03-15T01:15:00Z",
  "warnings": ["high_failure_rate", "volatile_pricing", "recent_complaints"],
  "recommendation": "block"
}
```

Or for an unknown endpoint:

```json
{
  "endpoint": "https://brand-new-service.xyz/api",
  "known": false,
  "report_count": 0,
  "warnings": ["unknown_endpoint"],
  "recommendation": "caution"
}
```

The recommendation is advisory. agent-budget decides what to do with it based on the owner's configured policies.

### Accepts anonymous reports

When an owner flags a bad transaction in agent-budget's dashboard ("Report" button), agent-budget hands the report to agent-trust. agent-trust sends an anonymous signal to the spendlog.ai reporting endpoint:

```json
{
  "endpoint_hash": "sha256:a1b2c3d4...",
  "outcome": "post_payment_failure",
  "amount_range": "0.01-0.10",
  "timestamp_bucket": "2026-03-15",
  "reporter_hash": "sha256:install_id_hash"
}
```

No user identity. No transaction details. No wallet address. No session context. Just: this endpoint, this outcome class, this rough price range, this day.

---

## Signal Types

### Positive signals (automatic, opt-in)

When the owner enables trust network participation (single toggle in settings), successful transactions automatically generate anonymous positive signals after agent-budget logs them. No human action required. This builds the baseline: "this service works and charges what it says."

Most transactions succeed, so positive signal volume builds the directory with minimal effort.

### Negative signals (manual, human-confirmed)

Failed transactions and bad experiences require the owner to click "Report" in agent-budget's dashboard. The human is the quality filter — you don't want agent bugs or network errors generating false complaints against good services.

Negative signals carry more weight in the trust score calculation than positive signals (a single confirmed failure matters more than one more success in a sea of successes).

### Anomalous pricing signals (auto-detected, human-confirmed)

When agent-budget detects a charge significantly above the median for that endpoint (using agent-trust's price data), it highlights the transaction in the dashboard. The owner confirms "yes, this was wrong" or dismisses it. Confirmed anomalies become negative signals with a `price_anomaly` tag.

---

## Architecture

### Skill Component

```
~/.openclaw/skills/agent-trust/
├── SKILL.md                    # Skill instructions for the agent
├── scripts/
│   ├── sync-trust-db.sh        # Downloads trust.json from CDN
│   ├── check-endpoint.sh       # Queries local trust DB for an endpoint
│   ├── report.sh               # Sends anonymous signal to reporting endpoint
│   └── status.sh               # Shows trust DB age, coverage, sync status
├── data/
│   ├── trust.json              # Local copy of trust database (downloaded nightly)
│   └── pending-reports.jsonl   # Reports queued for submission
└── references/
    └── signal-format.md        # Signal schema documentation
```

### Trust Database Format

`trust.json` is a flat lookup keyed by SHA-256 hash of the endpoint URL:

```json
{
  "version": "2026-03-15",
  "generated_at": "2026-03-15T04:00:00Z",
  "endpoint_count": 2847,
  "endpoints": {
    "sha256:a1b2c3d4...": {
      "url_hint": "stockdata.xyz",
      "report_count": 347,
      "success_rate": 0.97,
      "median_price_usd": 0.03,
      "price_p10_usd": 0.02,
      "price_p90_usd": 0.05,
      "first_seen": "2026-01-20",
      "last_success": "2026-03-15",
      "last_failure": "2026-03-14",
      "failure_types": {
        "post_payment": 8,
        "pre_payment": 3
      },
      "warnings": [],
      "score": 94
    },
    "sha256:e5f6g7h8...": {
      "url_hint": "shady-data.xyz",
      "report_count": 12,
      "success_rate": 0.42,
      "median_price_usd": 0.50,
      "price_p10_usd": 0.05,
      "price_p90_usd": 2.00,
      "first_seen": "2026-03-10",
      "last_success": "2026-03-12",
      "last_failure": "2026-03-15",
      "failure_types": {
        "post_payment": 7,
        "pre_payment": 0
      },
      "warnings": ["high_failure_rate", "volatile_pricing"],
      "score": 23
    }
  }
}
```

### URL Hashing

Endpoint URLs are hashed (SHA-256) in both the trust database and signals. The `url_hint` field contains only the hostname (no path, no query parameters) for human readability in the dashboard. Full URLs are never stored in the shared trust database — only locally in agent-budget's transaction log.

This prevents the trust database from becoming a directory of "here's every paid API on the internet with its exact path." The hash is enough for lookup; the hint is enough for display.

### Score Calculation

The trust score (0-100) is computed from:

- **Base score**: Starts at 50 for any endpoint with reports
- **Success rate**: Primary factor. 97% success → high score. 42% success → low score.
- **Report volume**: More reports increase confidence. 5 reports and 100% success scores lower than 500 reports and 97% success.
- **Recency**: Recent failures weigh more than old ones. A failure yesterday matters more than a failure two months ago.
- **Price stability**: Volatile pricing reduces the score (indicates inconsistent service or potential manipulation).
- **Age**: Newer endpoints start with lower scores regardless of success rate (insufficient data).

The exact formula is documented in `references/signal-format.md` and open source. Users can verify how scores are computed.

Unknown endpoints (not in the database) have no score. agent-trust returns `known: false` and lets agent-budget's policy decide what to do.

---

## Integration with agent-budget

### agent-budget is the primary interface

The owner never interacts with agent-trust directly. Everything happens through agent-budget's dashboard:

- Trust scores appear on transaction rows ("this service has a 94 trust score")
- Warnings appear before payments ("unknown endpoint — no trust data available")
- The "Report" button in agent-budget triggers agent-trust's reporting flow
- Trust network opt-in is a toggle in agent-budget's settings (which agent-trust reads)

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
                                       Signals aggregated
                                       trust.json rebuilt
                                       Pushed to Cloudflare CDN

Next day sync                    ◄───  Downloads fresh trust.json
```

### Recommendation → Policy mapping

agent-trust returns a recommendation. agent-budget maps it to an action based on the owner's configured policy:

| Recommendation | Default Policy | Owner can change to |
|---|---|---|
| `allow` | Proceed silently | Block, ask |
| `caution` | Proceed with dashboard warning | Block, ask |
| `block` | Block and notify owner | Allow, ask |

The owner configures this in agent-budget's settings, not agent-trust. agent-trust provides data; agent-budget makes decisions.

---

## Security & Privacy

### What agent-trust NEVER sees

- Individual transaction details (amounts, timestamps, services, sessions)
- Wallet addresses or balances
- User identity or API keys
- Agent-budget's transaction log

### What agent-trust sends (only with opt-in)

- Anonymous outcome signals (success/failure + rough price range + day)
- Manual reports (human-confirmed, same anonymous format)

### What agent-trust downloads

- trust.json from CDN (public, same file for everyone)
- No cookies, no tracking, no user-specific content

### Reporter privacy

- `reporter_hash` is a one-way hash of the installation ID. It allows deduplication (one report per endpoint per installation per day) without identifying the reporter.
- The installation ID itself is generated locally and never sent to the server.

### Abuse prevention

- **Sybil resistance**: One report per endpoint per installation per day. Creating fake installations to spam reports is possible but expensive relative to the impact.
- **Confirmation weighting**: Human-confirmed negative signals weigh more than automatic positive signals. Flooding with fake positive signals can't drown out real complaints.
- **Minimum report threshold**: Endpoints with fewer than 5 reports show "limited data" warning instead of a definitive score. Prevents gaming with a handful of fake signals.
- **Anomaly detection on signals**: The server-side aggregation flags unusual reporting patterns (e.g., 1000 positive reports for a brand-new endpoint in one day).

---

## Configuration

### Installation

```bash
clawhub install agent-trust
```

### Settings

In `~/.openclaw/openclaw.json`:

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

### Opt-in levels

1. **Download only** (default): Pull trust scores, use them for pre-transaction checks. Send nothing. Full value from the network with zero contribution.
2. **Report only**: Download scores + send manual reports when the owner clicks "Report." Contributes complaint data only.
3. **Full participation**: Download scores + send manual reports + send automatic positive signals. Maximum contribution, maximum network benefit.

Level 1 is the default because trust must be earned. The skill proves its value before asking for data.

---

## Server-Side Components

Hosted on the spendlog.ai droplet (Hetzner + Cloudflare):

### Reporting endpoint

`POST https://api.spendlog.ai/reports`

Accepts anonymous signals. Validates format, checks rate limits (max 100 signals per reporter_hash per day), appends to a processing queue.

### Aggregation pipeline

Runs nightly (or more frequently as volume grows):

1. Read all signals from the queue
2. Deduplicate (same reporter + same endpoint + same day = one signal)
3. For each endpoint: recompute report count, success rate, median price, price range, failure types, score
4. Generate new trust.json
5. Push to Cloudflare CDN
6. Archive processed signals

### CDN delivery

`GET https://cdn.spendlog.ai/trust.json`

Served from Cloudflare's edge. Cache TTL: 1 hour (allows intra-day updates if needed, but clients only check daily by default). The file is small (~50KB for thousands of endpoints) and compresses well.

---

## Future Expansion

### Price crawling (v0.2+)

A crawler hits known x402 endpoints and records the 402 response (price, currency, network) without paying. The 402 response is free — it's the menu, not the meal. Daily crawling builds a price history independent of user signals. This enables:

- "This service normally charges $0.03" without needing user reports to establish the baseline
- Price trend tracking (is this service getting more expensive?)
- New service discovery (find endpoints that started returning 402 recently)

### Service directory (v0.3+)

If you're crawling endpoints and tracking prices, you're building a database of agent-accessible services. What exists, what it costs, whether pricing is stable. Agents can query: "what are the cheapest reliable stock data APIs?" This is x402 Bazaar from the buyer's side.

### BBB-style quality reporting (v0.3+)

Beyond binary success/failure, structured quality reports: "service returned data but it was outdated," "service was slow (>10s response)," "service returned partial data." More nuanced than pass/fail, more useful for service improvement.

### Blacklist/whitelist endpoint feeds (v0.3+)

Curated lists of endpoints based on trust scores and community reports. agent-budget can subscribe to these feeds and automatically block or allow endpoints without per-service configuration.

---

## Relationship to Existing Ecosystem

### What exists (security scanning)

ClawScan, ClawSecure, Cisco scanner, VirusTotal — all scan skill *code* for malware before installation. This is supply chain security.

agent-trust is different. It monitors *economic behavior* of services that agents interact with at runtime. A service can pass every code scan and still charge 100x normal price or accept payment without delivering data. agent-trust catches that.

### What exists (service discovery)

x402 Bazaar (Coinbase) lets services publish themselves. Skillz Market lets agents discover paid skills. These are merchant-side directories.

agent-trust is buyer-side intelligence — what do agents actually experience when they pay these services? Directories say "here's what I charge." agent-trust says "here's what everyone's actually paying and whether they got what they paid for."

### What doesn't exist

Pre-transaction verification for agent payments. Price history tracking. Service quality scoring from buyer-reported outcomes. Anomaly detection based on market rates. This is all open space.

---

## Design Principles

1. **Privacy by default.** Download-only mode requires zero data sharing. Participation is opt-in and anonymous.

2. **Useful alone, better together.** agent-trust adds value to agent-budget. agent-budget works fine without it.

3. **Signals, not logs.** The network runs on anonymous outcome signals. Individual transaction details never leave the local machine.

4. **The human is the quality filter.** Positive signals can be automatic. Negative signals require human confirmation. This prevents agent bugs from poisoning the trust database.

5. **Trust the math, show the work.** Score calculation is open source and documented. Users can verify how scores are computed. No black-box reputation.

6. **Nightly, not real-time.** Trust scores update daily, not per-transaction. This is intentional: it prevents the server from learning transaction patterns ("agent X checked endpoint Y at 3:47pm"), keeps the architecture simple, and is more than fast enough for trust scoring (service quality doesn't change minute-to-minute).