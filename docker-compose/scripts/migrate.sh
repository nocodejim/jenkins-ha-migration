#!/bin/bash
set -euo pipefail

# Jenkins Migration Script
# Migrates Jenkins data to new deployment

BACKUP_FILE="/backup/jenkins-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
JENKINS_HOME="/var/jenkins_home"

# Stop Jenkins
if docker-compose ps | grep -q jenkins; then
    docker-compose stop jenkins
fi

# Backup current data
tar -czf "$BACKUP_FILE" -C "$JENKINS_HOME" jobs users secrets plugins *.xml

echo "Backup complete: $BACKUP_FILE"

echo "Copy backup to new server and restore using restore.sh"
