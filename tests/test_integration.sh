#!/bin/bash
set -euo pipefail

echo "Running integration tests..."

# Function to wait for Jenkins
wait_for_jenkins() {
    local url=$1
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for Jenkins at $url..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$url/login" | grep -q "200\|401\|403"; then
            echo "✓ Jenkins is responding"
            return 0
        fi
        echo "Attempt $((attempt + 1))/$max_attempts: Jenkins not ready yet..."
        sleep 10
        attempt=$((attempt + 1))
    done
    
    echo "✗ Jenkins failed to become ready"
    return 1
}

# Test Docker Compose deployment
echo "Test 1: Docker Compose deployment..."
cd docker-compose
docker-compose up -d
wait_for_jenkins "http://localhost:8080"
docker-compose down
cd ..
echo "✓ Docker Compose test passed"

echo "All integration tests passed!"
