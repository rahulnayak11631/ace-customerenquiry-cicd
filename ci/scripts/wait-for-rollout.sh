#!/usr/bin/env bash
# Usage: wait-for-rollout.sh <namespace> <timeout seconds>
set -euo pipefail
NAMESPACE="$1"
TIMEOUT="${2:-180}"
kubectl rollout status deployment/customerenquiry-api -n "$NAMESPACE" --timeout="${TIMEOUT}s"
