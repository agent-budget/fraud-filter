#!/usr/bin/env bash
# sync-trust-db.sh — Download the latest trust database from CDN.
#
# Usage:
#   sync-trust-db.sh           — Download trust.json from configured CDN URL
#   sync-trust-db.sh --force   — Download even if recently synced
#   sync-trust-db.sh --url URL — Download from a specific URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
DB_PATH="$DATA_DIR/trust.json"
CONFIG_PATH="$DATA_DIR/config.json"

mkdir -p "$DATA_DIR"

# Parse arguments
FORCE=false
CUSTOM_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --url) CUSTOM_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Read CDN URL from config or use default
if [ -n "$CUSTOM_URL" ]; then
  CDN_URL="$CUSTOM_URL"
elif [ -f "$CONFIG_PATH" ]; then
  CDN_URL=$(node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    try {
      const c = JSON.parse(readFileSync('${CONFIG_PATH}', 'utf-8'));
      console.log(c.trust_db_url || 'https://cdn.spendlog.ai/trust.json');
    } catch { console.log('https://cdn.spendlog.ai/trust.json'); }
  ")
else
  CDN_URL="https://cdn.spendlog.ai/trust.json"
fi

# Check if we should skip (synced within last 24 hours)
if [ "$FORCE" = false ] && [ -f "$DB_PATH" ]; then
  AGE_HOURS=$(node --input-type=module -e "
    import { statSync } from 'node:fs';
    const age = (Date.now() - statSync('${DB_PATH}').mtimeMs) / 3600000;
    console.log(Math.floor(age));
  ")
  if [ "$AGE_HOURS" -lt 24 ]; then
    echo "Trust DB is ${AGE_HOURS}h old (< 24h). Use --force to re-download."
    exit 0
  fi
fi

echo "Downloading trust database from: $CDN_URL"

# Download with curl, fall back to wget
TEMP_PATH="$DB_PATH.tmp"
if command -v curl &>/dev/null; then
  HTTP_CODE=$(curl -sS -w "%{http_code}" -o "$TEMP_PATH" "$CDN_URL" 2>/dev/null || echo "000")
elif command -v wget &>/dev/null; then
  wget -q -O "$TEMP_PATH" "$CDN_URL" 2>/dev/null && HTTP_CODE="200" || HTTP_CODE="000"
else
  echo "Error: neither curl nor wget found" >&2
  exit 1
fi

if [ "$HTTP_CODE" = "200" ] && [ -f "$TEMP_PATH" ] && [ -s "$TEMP_PATH" ]; then
  # Validate JSON
  if node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    const d = JSON.parse(readFileSync('${TEMP_PATH}', 'utf-8'));
    if (!d.endpoints) throw new Error('missing endpoints field');
    console.log('Valid: ' + Object.keys(d.endpoints).length + ' endpoints');
  " 2>/dev/null; then
    mv "$TEMP_PATH" "$DB_PATH"
    chmod 600 "$DB_PATH"
    echo "Trust database updated successfully."
  else
    rm -f "$TEMP_PATH"
    echo "Error: downloaded file is not valid trust.json" >&2
    exit 1
  fi
else
  rm -f "$TEMP_PATH"
  echo "Error: download failed (HTTP $HTTP_CODE)" >&2
  exit 1
fi
