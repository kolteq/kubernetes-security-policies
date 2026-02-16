#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Running PeerAuthentication tests..."
./PeerAuthentication/test_PeerAuthentication.sh

echo "Running AuthorizationPolicy tests..."
./AuthorizationPolicy/test_AuthorizationPolicy.sh

echo "Running RequestAuthentication tests..."
./RequestAuthentication/test_RequestAuthentication.sh

echo "All tests completed successfully."
