#!/bin/bash
set -euo pipefail

# Jenkins Restore Script
# Restores Jenkins home directory from backup

BACKUP_FILE="$1"
JENKINS_HOME="/var/jenkins_home"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup-file>"
    exit 1
fi

tar -xzf "$BACKUP_FILE" -C "$JENKINS_HOME"

echo "Restore complete."
