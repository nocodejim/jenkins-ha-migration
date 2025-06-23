#!/bin/bash
set -euo pipefail

echo "Running Helm chart tests..."

# Test 1: Lint the chart
echo "Test 1: Linting Helm chart..."
helm lint kubernetes/helm
echo "✓ Helm lint passed"

# Test 2: Template rendering
echo "Test 2: Testing template rendering..."
helm template test-release kubernetes/helm > /tmp/helm-output.yaml
echo "✓ Template rendering passed"

# Test 3: Validate Kubernetes manifests
echo "Test 3: Validating Kubernetes manifests..."
kubectl apply --dry-run=client -f /tmp/helm-output.yaml
echo "✓ Kubernetes validation passed"

# Test 4: Check required values
echo "Test 4: Checking required values..."
required_values=("namespace" "image.repository" "image.tag" "persistence.size")
for value in "${required_values[@]}"; do
    if ! grep -q "$value:" kubernetes/helm/values.yaml; then
        echo "✗ Missing required value: $value"
        exit 1
    fi
done
echo "✓ Required values check passed"

echo "All Helm tests passed!"
