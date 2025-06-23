#!/bin/bash
set -euo pipefail

# Jenkins Migration Assessment Script
# Analyzes current Jenkins instance for migration readiness

echo "Jenkins Migration Assessment"
echo "==========================="
echo

# Check if running on Windows (Git Bash) or Linux
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
    echo "Detected Windows environment"
    IS_WINDOWS=true
else
    echo "Detected Unix-like environment"
    IS_WINDOWS=false
fi

# Function to check Jenkins URL
check_jenkins_url() {
    echo -n "Enter your Jenkins URL (e.g., http://localhost:8080): "
    read -r JENKINS_URL
    
    if curl -s -o /dev/null -w "%{http_code}" "$JENKINS_URL/login" | grep -q "200\|401\|403"; then
        echo "✓ Jenkins is accessible at $JENKINS_URL"
        return 0
    else
        echo "✗ Cannot access Jenkins at $JENKINS_URL"
        return 1
    fi
}

# Function to check disk space
check_disk_space() {
    echo
    echo "Checking disk space requirements..."
    
    if [ "$IS_WINDOWS" = true ]; then
        # Windows disk check
        df -h | grep -E "^C:|^/c" || df -h
    else
        # Linux disk check
        df -h /var/lib/jenkins || df -h .
    fi
    
    echo
    echo "Recommendation: Ensure at least 100GB free space for migration"
}
# Function to estimate migration time
estimate_migration_time() {
    echo
    echo "Migration Time Estimation"
    echo "------------------------"
    echo "- Small instance (<10GB, <50 jobs): 30-60 minutes"
    echo "- Medium instance (10-50GB, 50-200 jobs): 1-3 hours"
    echo "- Large instance (50-100GB, 200-500 jobs): 3-6 hours"
    echo "- Extra large instance (>100GB, >500 jobs): 6-12 hours"
}

# Function to check prerequisites
check_prerequisites() {
    echo
    echo "Checking Prerequisites"
    echo "---------------------"
    
    # Check Docker
    if command -v docker &> /dev/null; then
        echo "✓ Docker is installed ($(docker --version))"
    else
        echo "✗ Docker is not installed - required for Docker Compose deployment"
    fi
    
    # Check kubectl
    if command -v kubectl &> /dev/null; then
        echo "✓ kubectl is installed ($(kubectl version --client --short 2>/dev/null))"
    else
        echo "✗ kubectl is not installed - required for Kubernetes deployment"
    fi
    
    # Check Helm
    if command -v helm &> /dev/null; then
        echo "✓ Helm is installed ($(helm version --short))"
    else
        echo "✗ Helm is not installed - required for Kubernetes deployment"
    fi
}

# Function to generate pre-migration checklist
generate_checklist() {
    echo
    echo "Pre-Migration Checklist"
    echo "----------------------"
    cat << EOF
□ Notify all users about the migration window
□ Stop all running builds
□ Disable all scheduled jobs
□ Document current Jenkins URL and important settings
□ List all installed plugins and versions
□ Document all global tool configurations
□ Export all credentials (securely)
□ Identify all build agents and their configurations
□ Review and document any custom scripts or configurations
□ Ensure backup storage is available (2x current Jenkins size)
□ Test backup and restore procedures
□ Plan rollback strategy
□ Schedule migration during low-usage period
□ Prepare DNS change if URL is changing
□ Review security groups/firewall rules for new deployment
EOF
}

# Main assessment flow
echo "This script will assess your Jenkins instance for migration readiness"
echo

# Check Jenkins accessibility
if ! check_jenkins_url; then
    echo "Please ensure Jenkins is running and accessible"
fi

# Check disk space
check_disk_space

# Check prerequisites
check_prerequisites

# Estimate migration time
estimate_migration_time

# Generate checklist
generate_checklist

# Generate assessment report
REPORT_FILE="migration-assessment-$(date +%Y%m%d_%H%M%S).txt"
{
    echo "Jenkins Migration Assessment Report"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Jenkins URL: ${JENKINS_URL:-Not specified}"
    echo
    echo "Environment: $OSTYPE"
    echo
    echo "Prerequisites Check:"
    echo "- Docker: $(command -v docker &> /dev/null && echo \"Installed\" || echo \"Not installed\")"
    echo "- kubectl: $(command -v kubectl &> /dev/null && echo \"Installed\" || echo \"Not installed\")"
    echo "- Helm: $(command -v helm &> /dev/null && echo \"Installed\" || echo \"Not installed\")"
    echo
    echo "Recommendations:"
    echo "1. Install any missing prerequisites"
    echo "2. Ensure adequate disk space (100GB+ free)"
    echo "3. Complete the pre-migration checklist"
    echo "4. Schedule migration during maintenance window"
    echo "5. Test backup and restore procedures first"
} > "$REPORT_FILE"

echo
echo "Assessment complete! Report saved to: $REPORT_FILE"
echo
echo "Next steps:"
echo "1. Review the assessment report"
echo "2. Address any missing prerequisites"
echo "3. Complete the pre-migration checklist"
echo "4. Run backup script when ready to migrate"
