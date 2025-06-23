#!/bin/bash
set -euo pipefail

# Jenkins Backup Script
# This script creates backups of Jenkins home directory

BACKUP_DIR="${BACKUP_DIR:-./backup}"
JENKINS_HOME="${JENKINS_HOME:-./docker-compose/jenkins_home}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="jenkins_backup_${TIMESTAMP}"

echo "[$(date)] Starting Jenkins backup..."

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Check if Jenkins home exists
if [ ! -d "$JENKINS_HOME" ]; then
    echo "Error: Jenkins home directory not found at $JENKINS_HOME"
    exit 1
fi

# Create backup
echo "[$(date)] Creating backup archive..."
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
    -C "$JENKINS_HOME" \
    --exclude='workspace/*' \
    --exclude='caches/*' \
    --exclude='logs/*' \
    .

# Calculate backup size
BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" | cut -f1)
echo "[$(date)] Backup created: ${BACKUP_NAME}.tar.gz (Size: $BACKUP_SIZE)"

# Clean old backups
echo "[$(date)] Cleaning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "jenkins_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

# List current backups
echo "[$(date)] Current backups:"
ls -lh "$BACKUP_DIR"/jenkins_backup_*.tar.gz 2>/dev/null || echo "No backups found"

echo "[$(date)] Backup completed successfully!"
