#!/bin/bash
set -euo pipefail

echo "Jenkins HA Migration Setup"
echo "========================="

# Check prerequisites
echo "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "Docker is required but not installed. Aborting." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "Git is required but not installed. Aborting." >&2; exit 1; }

# Make scripts executable
echo "Setting script permissions..."
find scripts -name "*.sh" -type f -exec chmod +x {} \;
find tests -name "*.sh" -type f -exec chmod +x {} \;

# Create necessary directories
echo "Creating directories..."
mkdir -p docker-compose/jenkins_home
mkdir -p backup
mkdir -p certs

# Set correct permissions
echo "Setting permissions..."
if [ -d "docker-compose/jenkins_home" ]; then
    sudo chown -R 1000:1000 docker-compose/jenkins_home || true
fi

# Generate self-signed certificate for testing
if [ ! -f "docker-compose/certs/cert.pem" ]; then
    echo "Generating self-signed certificate for testing..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout docker-compose/certs/key.pem \
        -out docker-compose/certs/cert.pem \
        -subj "/CN=jenkins.local" \
        2>/dev/null
fi

echo ""
echo "Setup complete! Next steps:"
echo "1. Review and update configuration files"
echo "2. For Kubernetes: Update kubernetes/helm/values.yaml"
echo "3. For Docker: Copy .env.example to .env and update"
echo "4. Run './scripts/assess-migration.sh' to assess your current Jenkins"
echo "5. Deploy using 'make deploy-k8s' or 'make deploy-docker'"
echo ""
echo "For detailed instructions, see README.md"
