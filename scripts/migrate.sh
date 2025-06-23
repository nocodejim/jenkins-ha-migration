#!/bin/bash
set -euo pipefail

# Jenkins Migration Script
# Migrates Jenkins from Windows to containerized deployment

echo "Jenkins Migration Tool"
echo "====================="

# Configuration
SOURCE_BACKUP="${1:-}"
TARGET_ENV="${2:-docker}"  # docker or kubernetes
TEMP_DIR="/tmp/jenkins-migration-$"

# Initialize variables that will be used later
JOB_COUNT=0
PLUGIN_COUNT=0
REPORT_FILE=""

# Check arguments
if [ -z "$SOURCE_BACKUP" ]; then
    echo "Usage: $0 <backup-file> [docker|kubernetes]"
    echo "Example: $0 jenkins-backup.zip docker"
    exit 1
fi

if [ ! -f "$SOURCE_BACKUP" ]; then
    echo "Error: Backup file not found: $SOURCE_BACKUP"
    exit 1
fi

# Create temporary directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo "[$(date)] Extracting backup..."
unzip -q "$SOURCE_BACKUP" -d "$TEMP_DIR" || {
    echo "Error: Failed to extract backup file"
    exit 1
}

# Analyze backup structure
echo "[$(date)] Analyzing backup structure..."
if [ -d "$TEMP_DIR/jobs" ]; then
    JOB_COUNT=$(find "$TEMP_DIR/jobs" -name "config.xml" | wc -l)
    echo "Found $JOB_COUNT jobs"
fi

if [ -d "$TEMP_DIR/plugins" ]; then
    PLUGIN_COUNT=$(ls -1 "$TEMP_DIR/plugins"/*.jpi 2>/dev/null | wc -l)
    echo "Found $PLUGIN_COUNT plugins"
fi

# Check for secrets
if [ -f "$TEMP_DIR/secret.key" ]; then
    echo "Found Jenkins secrets - will be preserved"
fi

# Prepare target directory based on environment
case "$TARGET_ENV" in
    docker)
        TARGET_DIR="./docker-compose/jenkins_home"
        echo "[$(date)] Preparing Docker Compose environment..."
        ;;
    kubernetes)
        TARGET_DIR="./temp-jenkins-home"
        echo "[$(date)] Preparing Kubernetes environment..."
        echo "Note: You'll need to copy data to PVC after this script"
        ;;
    *)
        echo "Error: Invalid target environment. Use 'docker' or 'kubernetes'"
        exit 1
        ;;
esac

# Create target directory
mkdir -p "$TARGET_DIR"

# Copy essential directories
echo "[$(date)] Copying Jenkins data..."
for dir in jobs users secrets plugins; do
    if [ -d "$TEMP_DIR/$dir" ]; then
        echo "Copying $dir..."
        cp -r "$TEMP_DIR/$dir" "$TARGET_DIR/"
    fi
done

# Copy essential files
for file in secret.key identity.key.enc secret.key.not-so-secret; do
    if [ -f "$TEMP_DIR/$file" ]; then
        echo "Copying $file..."
        cp "$TEMP_DIR/$file" "$TARGET_DIR/"
    fi
done

# Copy XML configuration files
echo "[$(date)] Copying configuration files..."
find "$TEMP_DIR" -maxdepth 1 -name "*.xml" -exec cp {} "$TARGET_DIR/" \;

# Set correct permissions
echo "[$(date)] Setting permissions..."
chown -R 1000:1000 "$TARGET_DIR" 2>/dev/null || {
    echo "Warning: Could not change ownership. You may need to run with sudo."
}

# Create migration report
REPORT_FILE="migration-report-$(date +%Y%m%d_%H%M%S).txt"
cat > "$REPORT_FILE" << REPORTEOF
Jenkins Migration Report
========================
Date: $(date)
Source: $SOURCE_BACKUP
Target: $TARGET_ENV
Target Directory: $TARGET_DIR

Summary:
- Jobs migrated: ${JOB_COUNT}
- Plugins found: ${PLUGIN_COUNT}
- Secrets preserved: $([ -f "$TEMP_DIR/secret.key" ] && echo "Yes" || echo "No")

Next Steps:
1. Review the migrated data in $TARGET_DIR
2. Start Jenkins using:
   - Docker: cd docker-compose && docker-compose up -d
   - Kubernetes: kubectl apply -f kubernetes/
3. Access Jenkins and verify:
   - All jobs are present
   - Plugins are loaded
   - Credentials work
4. Update Jenkins URL in system configuration
5. Reconfigure any agents/nodes

Notes:
- Workspaces were not migrated (will be recreated on first build)
- Build history has been preserved
- You may need to update plugin versions
REPORTEOF

echo
echo "[$(date)] Migration completed successfully!"
echo "Report saved to: $REPORT_FILE"
cat "$REPORT_FILE"
