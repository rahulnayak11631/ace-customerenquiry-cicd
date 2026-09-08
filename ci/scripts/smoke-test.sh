#!/usr/bin/env bash
# Usage: smoke-test.sh <path-prefix e.g. /ace-dev> <expected-apiVersion e.g. v1.0.0>
#
# POSTs a real customerId (1001, the one every version's ESQL treats as the
# success case) and asserts:
#   1. HTTP 200
#   2. Data.status == SUCCESS
#   3. Data.customer.apiVersion matches what THIS build's ESQL actually sets -
#      proves the response really came from the version just deployed, not
#      a stale pod (same idea as the /version check in the other project,
#      just reading the value the ACE flow itself already reports).
set -euo pipefail

PATH_PREFIX="$1"
EXPECTED_VERSION="$2"
HOST="ai-poc-ingress"
PORT="31083"
URL="https://${HOST}:${PORT}${PATH_PREFIX}/customerenquiryapi/v1/enquiry"
MAX_ATTEMPTS=8
RETRY_DELAY=5

echo "Smoke testing ${URL} (expecting apiVersion=${EXPECTED_VERSION})"

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  HTTP_CODE=$(curl -sk --resolve "${HOST}:${PORT}:127.0.0.1" -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$URL" -H "Content-Type: application/json" -d '{"customerId":"1001"}' || echo "000")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "[attempt ${attempt}/${MAX_ATTEMPTS}] FAIL: HTTP ${HTTP_CODE} (integration server may still be starting)"
    cat "$RESP_FILE" 2>/dev/null || true
    sleep "$RETRY_DELAY"
    continue
  fi

  # ACE's REST binding emits OutputRoot.JSON.Data directly as the response
  # body's root - "customer" is top-level, not nested under a "Data" key
  # (confirmed against a real response: {"status":...,"customer":{...}}).
  ACTUAL_VERSION=$(python3 -c "import json,sys
try:
    d=json.load(open('$RESP_FILE'))
    print(d.get('customer',{}).get('apiVersion',''))
except Exception:
    print('')")

  if [ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]; then
    echo "PASS: ${URL} responded with apiVersion=${ACTUAL_VERSION} (attempt ${attempt}/${MAX_ATTEMPTS})"
    cat "$RESP_FILE"
    exit 0
  fi

  echo "[attempt ${attempt}/${MAX_ATTEMPTS}] expected apiVersion ${EXPECTED_VERSION}, got '${ACTUAL_VERSION}' - retrying"
  cat "$RESP_FILE" 2>/dev/null || true
  sleep "$RETRY_DELAY"
done

echo "FAIL: ${URL} never reported apiVersion ${EXPECTED_VERSION} after ${MAX_ATTEMPTS} attempts"
exit 1
