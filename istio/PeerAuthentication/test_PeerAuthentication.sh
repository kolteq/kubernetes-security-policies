#!/usr/bin/env bash
set -euo pipefail

ROOT_NAMESPACE="${ROOT_NAMESPACE:-istio-system}"
TEST_NAMESPACE="${TEST_NAMESPACE:-pa-test}"
PLAIN_NAMESPACE="${PLAIN_NAMESPACE:-pa-plain}"
TIMEOUT="${TIMEOUT:-120s}"
CLEANUP="${CLEANUP:-true}"

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
    delete_in_namespace policies/mesh-wide-strict/policy.yaml "$ROOT_NAMESPACE" || true
    delete_in_namespace policies/namespace-permissive/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/workload-strict/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/port-level-exception/policy.yaml "$TEST_NAMESPACE" || true
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found
    kubectl delete namespace "$PLAIN_NAMESPACE" --ignore-not-found
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
kubectl label namespace "$TEST_NAMESPACE" istio.io/rev=default --overwrite

kubectl get namespace "$PLAIN_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$PLAIN_NAMESPACE"
kubectl label namespace "$PLAIN_NAMESPACE" istio.io/rev- --overwrite
kubectl label namespace "$PLAIN_NAMESPACE" istio-injection=disabled --overwrite

echo "Applying PeerAuthentication policies..."
apply_in_namespace policies/mesh-wide-strict/policy.yaml "$ROOT_NAMESPACE"
apply_in_namespace policies/namespace-permissive/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/workload-strict/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/port-level-exception/policy.yaml "$TEST_NAMESPACE"
echo "Policies under test: policies/mesh-wide-strict/policy.yaml, policies/namespace-permissive/policy.yaml, policies/workload-strict/policy.yaml, policies/port-level-exception/policy.yaml"

echo "Deploying test workloads..."
cat <<'EOF' | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  labels:
    app: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:0.2.3
        args: ["-text=payments"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments
spec:
  selector:
    app: payments
  ports:
  - name: http
    port: 8080
    targetPort: 8080
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
        - containerPort: 8080
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
    targetPort: 8080
---
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
        - containerPort: 8080
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
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-mtls
  labels:
    app: curl-mtls
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-mtls
  template:
    metadata:
      labels:
        app: curl-mtls
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3650"]
EOF

cat <<'EOF' | kubectl apply -n "$PLAIN_NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-plain
  labels:
    app: curl-plain
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-plain
  template:
    metadata:
      labels:
        app: curl-plain
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3650"]
EOF

echo "Waiting for pods to be ready..."
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=payments --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=api-gateway --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=public --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=curl-mtls --timeout="$TIMEOUT"
kubectl wait -n "$PLAIN_NAMESPACE" --for=condition=ready pod -l app=curl-plain --timeout="$TIMEOUT"

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

echo "Running tests..."

if kubectl exec -n "$TEST_NAMESPACE" deploy/curl-mtls -- \
  curl -sS "http://payments.${TEST_NAMESPACE}:8080/" >/dev/null; then
  pass_case "mTLS client can reach payments (STRICT workload)." \
    "policies/workload-strict/policy.yaml"
else
  fail_case "mTLS client cannot reach payments (STRICT workload)." \
    "policies/workload-strict/policy.yaml"
fi

if kubectl exec -n "$PLAIN_NAMESPACE" deploy/curl-plain -- \
  curl -sS "http://payments.${TEST_NAMESPACE}:8080/" >/dev/null; then
  fail_case "Plain client unexpectedly reached payments (STRICT workload)." \
    "policies/workload-strict/policy.yaml"
else
  pass_case "Plain client blocked from payments (STRICT workload)." \
    "policies/workload-strict/policy.yaml"
fi

if kubectl exec -n "$PLAIN_NAMESPACE" deploy/curl-plain -- \
  curl -sS "http://api-gateway.${TEST_NAMESPACE}:8080/" >/dev/null; then
  pass_case "Plain client can reach api-gateway port exception." \
    "policies/port-level-exception/policy.yaml"
else
  fail_case "Plain client cannot reach api-gateway port exception." \
    "policies/port-level-exception/policy.yaml"
fi

if kubectl exec -n "$PLAIN_NAMESPACE" deploy/curl-plain -- \
  curl -sS "http://public.${TEST_NAMESPACE}:8080/" >/dev/null; then
  pass_case "Plain client can reach public (namespace PERMISSIVE)." \
    "policies/namespace-permissive/policy.yaml"
else
  fail_case "Plain client cannot reach public (namespace PERMISSIVE)." \
    "policies/namespace-permissive/policy.yaml"
fi

echo "Tests complete: ${pass} passed, ${fail} failed."
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
