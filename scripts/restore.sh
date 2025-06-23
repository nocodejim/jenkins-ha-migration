#!/bin/bash
set -euo pipefail

# Jenkins Restore Script
# This script restores Jenkins from a backup

BACKUP_DIR="${BACKUP_DIR:-./backup}"
JENKINS_HOME="${JENKINS_HOME:-./docker-compose/jenkins_home}"

# Function to list available backups
list_backups() {
    echo "Available backups:"
    ls -1 "$BACKUP_DIR"/jenkins_backup_*.tar.gz 2>/dev/null | nl -v 0 || {
        echo "No backups found in $BACKUP_DIR"
        exit 1
    }
}

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory not found at $BACKUP_DIR"
    exit 1
fi

# List available backups
list_backups

# Prompt for backup selection
echo -n "Enter the number of the backup to restore (or 'latest' for most recent): "
read -r selection

# Determine backup file
if [ "$selection" = "latest" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/jenkins_backup_*.tar.gz 2>/dev/null | head -1)
else
    BACKUP_FILE=$(ls -1 "$BACKUP_DIR"/jenkins_backup_*.tar.gz 2>/dev/null | sed -n "$((selection+1))p")
fi

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Invalid selection or backup file not found"
    exit 1
fi

echo "Selected backup: $BACKUP_FILE"

# Confirmation
echo -n "This will replace the current Jenkins home directory. Continue? (yes/no): "
read -r confirm
if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled"
    exit 0
fi

# Stop Jenkins if running
if command -v docker-compose &> /dev/null; then
    echo "[$(date)] Stopping Jenkins services..."
    cd docker-compose && docker-compose down || true
    cd ..
fi

# Backup current Jenkins home
if [ -d "$JENKINS_HOME" ]; then
    echo "[$(date)] Backing up current Jenkins home..."
    mv "$JENKINS_HOME" "${JENKINS_HOME}.bak.$(date +%Y%m%d_%H%M%S)"
fi

# Create Jenkins home directory
mkdir -p "$JENKINS_HOME"

# Extract backup
echo "[$(date)] Restoring from backup..."
tar -xzf "$BACKUP_FILE" -C "$JENKINS_HOME"

# Set correct permissions
echo "[$(date)] Setting permissions..."
chown -R 1000:1000 "$JENKINS_HOME"

echo "[$(date)] Restore completed successfully!"
echo "You can now start Jenkins services"
