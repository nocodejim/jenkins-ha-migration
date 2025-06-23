# Jenkins Windows Backup Script
# Run as Administrator

param(
    [string]$JenkinsHome = "C:\ProgramData\Jenkins\.jenkins",
    [string]$BackupPath = "C:\jenkins-backup",
    [switch]$StopService = $false
)

Write-Host "Jenkins Backup Script" -ForegroundColor Green
Write-Host "===================" -ForegroundColor Green

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator. Exiting..."
    exit 1
}

# Check if Jenkins home exists
if (-not (Test-Path $JenkinsHome)) {
    Write-Error "Jenkins home directory not found at: $JenkinsHome"
    exit 1
}

# Create backup directory
Write-Host "Creating backup directory..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

# Stop Jenkins service if requested
if ($StopService) {
    Write-Host "Stopping Jenkins service..." -ForegroundColor Yellow
    Stop-Service -Name "Jenkins" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

# Backup timestamp
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupName = "jenkins_backup_$timestamp"

Write-Host "Starting backup to: $BackupPath\$backupName" -ForegroundColor Yellow

# Create backup using robocopy
$robocopyArgs = @(
    $JenkinsHome,
    "$BackupPath\$backupName",
    "/E",           # Copy subdirectories, including empty ones
    "/Z",           # Copy files in restartable mode
    "/R:3",         # Number of retries
    "/W:10",        # Wait time between retries
    "/NFL",         # No file list
    "/NDL",         # No directory list
    "/NP",          # No progress
    "/LOG:$BackupPath\robocopy_$timestamp.log"
)

Write-Host "Copying Jenkins data..." -ForegroundColor Yellow
$result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow

# Check robocopy exit code (0-7 are success codes)
if ($result.ExitCode -gt 7) {
    Write-Error "Robocopy failed with exit code: $($result.ExitCode)"
    exit 1
}

# Create ZIP archive
Write-Host "Creating ZIP archive..." -ForegroundColor Yellow
$zipPath = "$BackupPath\$backupName.zip"
Compress-Archive -Path "$BackupPath\$backupName" -DestinationPath $zipPath -CompressionLevel Optimal

# Calculate sizes
$backupSize = (Get-Item $zipPath).Length / 1MB
$originalSize = (Get-ChildItem $JenkinsHome -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB

Write-Host "`nBackup Summary:" -ForegroundColor Green
Write-Host "Original size: $([math]::Round($originalSize, 2)) MB" -ForegroundColor White
Write-Host "Backup size: $([math]::Round($backupSize, 2)) MB" -ForegroundColor White
Write-Host "Compression ratio: $([math]::Round(($backupSize / $originalSize) * 100, 2))%" -ForegroundColor White
Write-Host "Backup location: $zipPath" -ForegroundColor White

# Clean up uncompressed backup
Write-Host "`nCleaning up temporary files..." -ForegroundColor Yellow
Remove-Item -Path "$BackupPath\$backupName" -Recurse -Force

# Restart Jenkins service if it was stopped
if ($StopService) {
    Write-Host "Starting Jenkins service..." -ForegroundColor Yellow
    Start-Service -Name "Jenkins"
}

Write-Host "`nBackup completed successfully!" -ForegroundColor Green
