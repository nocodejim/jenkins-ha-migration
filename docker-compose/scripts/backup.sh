#!/bin/bash
set -euo pipefail

# Jenkins Backup Script
# Backs up Jenkins home directory and important configs

BACKUP_DIR="/backup"
JENKINS_HOME="/var/jenkins_home"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/jenkins-backup-$DATE.tar.gz"

mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_FILE" \
    -C "$JENKINS_HOME" \
    --exclude='workspace/*' \
    --exclude='caches/*' \
    jobs users secrets plugins *.xml

echo "Backup complete: $BACKUP_FILE"
