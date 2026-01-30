#!/usr/bin/env bash
set -euo pipefail

TEST_NAMESPACE="${TEST_NAMESPACE:-ap-test}"
OTHER_NAMESPACE="${OTHER_NAMESPACE:-ap-other}"
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

render_with_namespace() {
  local file="$1"
  local namespace="$2"
  if grep -qE '^  namespace:' "$file"; then
    sed -E "s/^  namespace: .*/  namespace: ${namespace}/" "$file"
  else
    awk -v ns="$namespace" '
      /^metadata:/ {print; print "  namespace: " ns; next}
      {print}
    ' "$file"
  fi
}

strip_ports_block() {
  awk '
    BEGIN {skip=0; indent=""}
    {
      if (skip) {
        if ($0 ~ "^" indent " ") { next }
        skip=0
      }
      if ($0 ~ /^[[:space:]]*ports:/) {
        indent = gensub(/^( *).*/, "\\1", 1, $0)
        skip=1
        next
      }
      print
    }
  '
}

render_policy() {
  local file="$1"
  local namespace="$2"
  local rendered
  rendered="$(render_with_namespace "$file" "$namespace")"
  case "$file" in
    *workload-allow-same-namespace*)
      rendered="$(printf '%s\n' "$rendered" | sed -E "s/^([[:space:]]*-[[:space:]]*)default$/\\1${namespace}/")"
      ;;
    *workload-allow-serviceaccount*)
      rendered="$(printf '%s\n' "$rendered" | sed -E "s#cluster\\.local/ns/[^/]+/sa/payments-client#cluster.local/ns/${namespace}/sa/payments-client#")"
      ;;
    *workload-allow-get*)
      rendered="$(printf '%s\n' "$rendered" | strip_ports_block)"
      ;;
  esac
  printf '%s\n' "$rendered"
}

apply_in_namespace() {
  local file="$1"
  local namespace="$2"
  render_policy "$file" "$namespace" | kubectl apply -f -
}

delete_in_namespace() {
  local file="$1"
  local namespace="$2"
  render_policy "$file" "$namespace" | kubectl delete --ignore-not-found -f -
}

verify_policies_in_namespace() {
  local namespace="$1"
  local missing=0
  for name in allow-same-namespace allow-serviceaccount allow-get-only deny-all; do
    if ! kubectl get authorizationpolicy -n "$namespace" "$name" >/dev/null 2>&1; then
      echo "Missing AuthorizationPolicy in namespace ${namespace}: ${name}" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    delete_in_namespace policies/workload-allow-same-namespace/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/workload-allow-serviceaccount/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/workload-allow-get/policy.yaml "$TEST_NAMESPACE" || true
    delete_in_namespace policies/workload-deny-all/policy.yaml "$TEST_NAMESPACE" || true
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found
    kubectl delete namespace "$OTHER_NAMESPACE" --ignore-not-found
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

kubectl get namespace "$OTHER_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$OTHER_NAMESPACE"
kubectl label namespace "$OTHER_NAMESPACE" istio-injection=enabled --overwrite

echo "Applying AuthorizationPolicy policies..."
apply_in_namespace policies/workload-allow-same-namespace/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/workload-allow-serviceaccount/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/workload-allow-get/policy.yaml "$TEST_NAMESPACE"
apply_in_namespace policies/workload-deny-all/policy.yaml "$TEST_NAMESPACE"
echo "Policies under test: policies/workload-allow-same-namespace/policy.yaml, policies/workload-allow-serviceaccount/policy.yaml, policies/workload-allow-get/policy.yaml, policies/workload-deny-all/policy.yaml"
verify_policies_in_namespace "$TEST_NAMESPACE"

echo "Deploying test workloads..."
cat <<'EOF' | kubectl apply -n "$TEST_NAMESPACE" -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-client
---
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
        - containerPort: 5678
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
  name: blocked
  labels:
    app: blocked
spec:
  replicas: 1
  selector:
    matchLabels:
      app: blocked
  template:
    metadata:
      labels:
        app: blocked
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:0.2.3
        args: ["-text=blocked"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: blocked
spec:
  selector:
    app: blocked
  ports:
  - name: http
    port: 8080
    targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-same-ns
  labels:
    app: curl-same-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-same-ns
  template:
    metadata:
      labels:
        app: curl-same-ns
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3650"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-payments
  labels:
    app: curl-payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-payments
  template:
    metadata:
      labels:
        app: curl-payments
    spec:
      serviceAccountName: payments-client
      containers:
      - name: curl
        image: curlimages/curl:8.5.0
        command: ["sleep", "3650"]
EOF

cat <<'EOF' | kubectl apply -n "$OTHER_NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-other-ns
  labels:
    app: curl-other-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: curl-other-ns
  template:
    metadata:
      labels:
        app: curl-other-ns
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
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=blocked --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=curl-same-ns --timeout="$TIMEOUT"
kubectl wait -n "$TEST_NAMESPACE" --for=condition=ready pod -l app=curl-payments --timeout="$TIMEOUT"
kubectl wait -n "$OTHER_NAMESPACE" --for=condition=ready pod -l app=curl-other-ns --timeout="$TIMEOUT"

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
  local client="$2"
  local method="$3"
  local url="$4"
  local code rc
  set +e
  if [[ -n "$method" ]]; then
    code=$(kubectl exec -n "$namespace" deploy/"$client" -- \
      curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url")
  else
    code=$(kubectl exec -n "$namespace" deploy/"$client" -- \
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

code=$(curl_status "$TEST_NAMESPACE" curl-same-ns "" "http://public.${TEST_NAMESPACE}:8080/")
expect_code "200" "$code" "Same-namespace client can reach public." \
  "policies/workload-allow-same-namespace/policy.yaml"

code=$(curl_status "$OTHER_NAMESPACE" curl-other-ns "" "http://public.${TEST_NAMESPACE}:8080/")
expect_code "403" "$code" "Other-namespace client blocked from public." \
  "policies/workload-allow-same-namespace/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" curl-payments "" "http://payments.${TEST_NAMESPACE}:8080/")
expect_code "200" "$code" "payments-client service account can reach payments." \
  "policies/workload-allow-serviceaccount/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" curl-same-ns "" "http://payments.${TEST_NAMESPACE}:8080/")
expect_code "403" "$code" "Non-allowed service account blocked from payments." \
  "policies/workload-allow-serviceaccount/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" curl-same-ns "GET" "http://api-gateway.${TEST_NAMESPACE}:8080/")
expect_code "200" "$code" "GET allowed to api-gateway." \
  "policies/workload-allow-get/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" curl-same-ns "POST" "http://api-gateway.${TEST_NAMESPACE}:8080/")
expect_code "403" "$code" "POST denied to api-gateway." \
  "policies/workload-allow-get/policy.yaml"

code=$(curl_status "$TEST_NAMESPACE" curl-same-ns "" "http://blocked.${TEST_NAMESPACE}:8080/")
expect_code "403" "$code" "Deny-all blocks access to blocked workload." \
  "policies/workload-deny-all/policy.yaml"

echo "Tests complete: ${pass} passed, ${fail} failed."
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
