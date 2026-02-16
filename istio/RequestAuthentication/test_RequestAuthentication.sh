#!/usr/bin/env bash
set -euo pipefail

TEST_NAMESPACE="${TEST_NAMESPACE:-ra-test}"
TIMEOUT="${TIMEOUT:-120s}"
CLEANUP="${CLEANUP:-true}"

TOKEN_AUD_API="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2V5LTEifQ.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlLmNvbSIsInN1YiI6InVzZXIxIiwiZXhwIjoxODMyODgwMzg2LCJhdWQiOiJhcGkifQ.H6k96kWcPTV1AJnKV7Jym86PoG0K3SbNrK0N2SNqml6-9KD-wNN2wRU33gcM6MLQIfHeagBEgS6n4ztEEoNozkXCxmEx_jx2hNcPLh3foeGc7H5Xt7nQ3fdKrZGIDU_17KdHM6EnyGJ1wIaNFKnCrsYgqzzbWZRGAoOaJjjuO2xEDoVGJc9gVyroF1YZOednl9ruHPue_9CzdDscGpSrSUCbqeomXzhajl8VdYu_UhZa30enCuMFfwWisG3AdhChLdjKS98JWB8kw7sA9V8NtZi8at0GYAeeFWeUtNQ-LAGCeSBGb8Qf-czCZr2BvKeUHU6mxGJs1W_NuolVKWbn5g"
TOKEN_AUD_OTHER="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2V5LTEifQ.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlLmNvbSIsInN1YiI6InVzZXIxIiwiZXhwIjoxODMyODgwMzg2LCJhdWQiOiJvdGhlciJ9.jiXAzzXP5kx2DofeM8Bo1ZXOC_7RTgI3Staki7mU49cr_hyo2Pr3295Zhe4Xrnee2cC8s8T07d1gQojKZ_tKWg5s_4Fg50DNRjtJu8vJvE3uoVqaqJgjW4aj3hgH5gkQObim2buA_xjF3PLHyE0D23HkHw7kZNNulCHm3FIeZC6QqcDzsgAlPzsYVU0a7LZojxsEkHLFRN8f3GiLu2v3A8s0ydIkpiq7r6JNHbSl29S49GQtfAtrw7xCd2c2BEPsqhU44bqTKiNSZyXkD22_ph8eBakyCXxXSYHPeFmsKRbiFZTYLi9DswnT6iB_5VffcaMxXfdHxmIS3jMh1jKG_Q"
TOKEN_NO_AUD="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2V5LTEifQ.eyJpc3MiOiJodHRwczovL2lzc3Vlci5leGFtcGxlLmNvbSIsInN1YiI6InVzZXIxIiwiZXhwIjoxODMyODgwMzg2fQ.bZVa1LaMReeGIUUcbq6ylJ4T0MkI3xJgSJ5Id50GN_M7NTHu08Va-jmCgbmzpp7GqrH-k5ch82BjRlc_PMu_MA_f_EqfeUn6MA8WgbQP9AbcLWKLeazJgJ-GpCr1bgIZ92bAJnV_oe5u7zpmZ617nWGIk5nea-m2Zqqh_VV_nDKoiybnRYUvBb8DrckfPni2i27IlFnaSN58ZNHoJCBzpwKgB0-wVl1lzHrHkMRsiaiYTv49K3H1MRtrXH5WRUKYpa30ZVnInEridcF6qc6HPW19LyhMHUzEUhZngtdpwNfzhtxX-gs08Q_Hv_PO0wppUnn59kxOSts7jcGEG3Fafg"
TOKEN_INVALID="bad.token.value"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

istio_installed() {
  kubectl get namespace istio-system >/dev/null 2>&1 || return 1
  kubectl get deploy -n istio-system istiod >/dev/null 2>&1 || return 1
  return 0
}

ensure_istio() {
  if istio_installed; then
    echo "Istio already installed; skipping install."
    return 0
  fi
  require_cmd helm
  echo "Installing Istio..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts
  helm repo update
  helm install istio-base istio/base -n istio-system --set defaultRevision=default --create-namespace
  helm install istiod istio/istiod -n istio-system --wait
}

apply_in_namespace() {
  local file="$1"
  local namespace="$2"
  sed -E "s/^  namespace: .*/  namespace: ${namespace}/" "$file" | kubectl apply -f -
}

delete_in_namespace() {
  local file="$1"
  local namespace="$2"
  sed -E "s/^  namespace: .*/  namespace: ${namespace}/" "$file" | kubectl delete --ignore-not-found -f -
}

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    delete_in_namespace policies/workload-jwt-validate/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/workload-jwt-audience/policy.yaml "$TEST_NAMESPACE" || true
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found
    echo "Cleanup complete."
  fi
}

trap cleanup EXIT

require_cmd kubectl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Using context: $(kubectl config current-context)"

ensure_istio

kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$TEST_NAMESPACE"
kubectl label namespace "$TEST_NAMESPACE" istio-injection=enabled --overwrite

echo "Applying RequestAuthentication policies..."
apply_in_namespace policies/workload-jwt-validate/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/workload-jwt-audience/policy.yaml "$TEST_NAMESPACE"
echo "Policies under test: policies/workload-jwt-validate/policy.yaml, policies/workload-jwt-audience/policy.yaml"

echo "Deploying test workloads..."
cat <<'EOF' | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: public
  labels:
    app: public
spec:
  replicas: 1
  selector:
    matchLabels:
      app: public
  template:
    metadata:
      labels:
        app: public
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:0.2.3
        args: ["-text=public"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: public
spec:
  selector:
    app: public
  ports:
  - name: http
    port: 8080
    targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  labels:
    app: api-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:0.2.3
        args: ["-text=api-gateway"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
spec:
  selector:
    app: api-gateway
  ports:
  - name: http
    port: 8080
    targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl
  labels:
    app: curl
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl
  template:
    metadata:
      labels:
        app: curl
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3650"]
EOF

echo "Waiting for pods to be ready..."
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=public --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=api-gateway --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=curl --timeout="$TIMEOUT"

pass=0
fail=0

pass_case() {
  local desc="$1"
  local policy="${2:-}"
  pass=$((pass + 1))
  if [[ -n "$policy" ]]; then
    echo "PASS: ${desc} [policy: ${policy}]"
  else
    echo "PASS: ${desc}"
  fi
}

fail_case() {
  local desc="$1"
  local policy="${2:-}"
  fail=$((fail + 1))
  if [[ -n "$policy" ]]; then
    echo "FAIL: ${desc} [policy: ${policy}]"
  else
    echo "FAIL: ${desc}"
  fi
}

curl_status() {
  local namespace="$1"
  local url="$2"
  local token="${3:-}"
  local code rc
  set +e
  if [[ -n "$token" ]]; then
    code=$(kubectl exec -n "$namespace" deploy/curl -- \
      curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${token}" "$url")
  else
    code=$(kubectl exec -n "$namespace" deploy/curl -- \
      curl -sS -o /dev/null -w "%{http_code}" "$url")
  fi
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "000"
  else
    echo "$code"
  fi
}

expect_code() {
  local expected="$1"
  local actual="$2"
  local desc="$3"
  local policy="${4:-}"
  if [[ "$actual" == "$expected" ]]; then
    pass_case "$desc" "$policy"
  else
    fail_case "$desc (expected ${expected}, got ${actual})" "$policy"
  fi
}

echo "Running tests..."

code=$(curl_status "$TEST_NAMESPACE" "http://public.${TEST_NAMESPACE}:8080/")
expect_code "200" "$code" "Public allows request without JWT (validation only)." \
  "policies/workload-jwt-validate/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" "http://public.${TEST_NAMESPACE}:8080/" "$TOKEN_NO_AUD")
expect_code "200" "$code" "Public accepts valid JWT." \
  "policies/workload-jwt-validate/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" "http://public.${TEST_NAMESPACE}:8080/" "$TOKEN_INVALID")
expect_code "401" "$code" "Public rejects invalid JWT." \
  "policies/workload-jwt-validate/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" "http://api-gateway.${TEST_NAMESPACE}:8080/" "$TOKEN_AUD_API")
expect_code "200" "$code" "API gateway accepts JWT with required audience." \
  "policies/workload-jwt-audience/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" "http://api-gateway.${TEST_NAMESPACE}:8080/" "$TOKEN_AUD_OTHER")
expect_code "403" "$code" "API gateway rejects JWT with wrong audience." \
  "policies/workload-jwt-audience/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" "http://api-gateway.${TEST_NAMESPACE}:8080/")
expect_code "200" "$code" "API gateway allows request without JWT (validation only)." \
  "policies/workload-jwt-audience/policy.yaml"

echo "Tests complete: ${pass} passed, ${fail} failed."
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
