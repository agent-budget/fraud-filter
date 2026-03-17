#!/usr/bin/env bash
# report.sh — Queue an anonymous report for an endpoint.
#
# Usage:
#   report.sh <url> <outcome> [amount_usd]
#
# Outcomes: success, post_payment_failure, pre_payment_failure
#
# Examples:
#   report.sh https://api.example.com/data post_payment_failure 0.05
#   report.sh https://api.example.com/data success

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/../server"

if [ $# -lt 2 ]; then
  echo "Usage: report.sh <endpoint-url> <outcome> [amount_usd]" >&2
  echo "Outcomes: success, post_payment_failure, pre_payment_failure" >&2
  exit 1
fi

URL="$1"
OUTCOME="$2"
AMOUNT="${3:-0}"

node --input-type=module -e "
  import { queueReport } from '${SERVER_DIR}/reporter.js';

  const url = process.argv[1];
  const outcome = process.argv[2];
  const amount = process.argv[3];

  const validOutcomes = ['success', 'post_payment_failure', 'pre_payment_failure'];
  if (!validOutcomes.includes(outcome)) {
    console.error('Invalid outcome: ' + outcome);
    console.error('Valid outcomes: ' + validOutcomes.join(', '));
    process.exit(1);
  }

  const result = queueReport({ endpoint_url: url, outcome, amount_usd: amount });
  console.log(JSON.stringify(result, null, 2));
" "$URL" "$OUTCOME" "$AMOUNT"
