#!/bin/bash

# Jenkins Migration Project Setup Script
# This script creates a complete Jenkins HA deployment project with Kubernetes and Docker Compose options
# Including all documentation, CI/CD pipelines, and security configurations

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Project configuration
PROJECT_NAME="jenkins-ha-migration"
GITHUB_USERNAME="${GITHUB_USERNAME:-your-github-username}"
GITHUB_EMAIL="${GITHUB_EMAIL:-your-email@example.com}"

print_status "Creating Jenkins HA Migration Project..."

# Create project root directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize git repository
print_status "Initializing Git repository..."
git init
git config user.name "$GITHUB_USERNAME"
git config user.email "$GITHUB_EMAIL"

# Create directory structure
print_status "Creating directory structure..."
mkdir -p {kubernetes/helm/{templates,charts},docker-compose/{nginx,certs,monitoring,scripts},docs,scripts,ci-cd/{github,gitlab,jenkins},monitoring/{prometheus,grafana/dashboards},security,tests,backup}

# docs/migration-guide.md
cat > docs/migration-guide.md << 'EOF'
# Jenkins Migration Guide

This comprehensive guide walks you through migrating from Jenkins on Windows Server 2016 to a containerized deployment.

## Pre-Migration Checklist

### 1. Assessment Phase
- [ ] Run migration assessment: `./scripts/assess-migration.sh`
- [ ] Document current Jenkins version
- [ ] List all installed plugins and versions
- [ ] Document all global configurations
- [ ] Identify all build agents
- [ ] Review disk space requirements (need 2x current size)
- [ ] Plan migration window (4-8 hours recommended)

### 2. Preparation Phase
- [ ] Notify all users about migration
- [ ] Stop all running builds
- [ ] Disable all scheduled jobs
- [ ] Install backup plugin (ThinBackup recommended)
- [ ] Test backup and restore procedures
- [ ] Prepare target environment (Kubernetes/Docker)

## Migration Steps

### Step 1: Backup Current Jenkins

#### Option A: Using ThinBackup Plugin

1. Install ThinBackup plugin:
   - Manage Jenkins → Plugin Manager → Available
   - Search for "ThinBackup"
   - Install and restart

2. Configure backup:
   - Manage Jenkins → ThinBackup → Settings
   - Backup directory: `C:\jenkins-backup`
   - Check all backup options
   - Save configuration

3. Run full backup:
   - Manage Jenkins → ThinBackup → Backup Now
   - Wait for completion

#### Option B: Manual Backup

1. Stop Jenkins service:
```powershell
Stop-Service Jenkins
```

2. Run backup script:
```powershell
# Run as Administrator
$jenkinsHome = "C:\ProgramData\Jenkins\.jenkins"
$backupPath = "C:\jenkins-backup"

# Create backup
New-Item -ItemType Directory -Force -Path $backupPath
robocopy "$jenkinsHome" "$backupPath" /E /Z /R:3 /W:10

# Create archive
Compress-Archive -Path $backupPath -DestinationPath "jenkins-backup-$(Get-Date -Format 'yyyyMMdd').zip"
```

### Step 2: Prepare Target Environment

#### For Kubernetes:

1. Configure storage class:
```bash
# Check available storage classes
kubectl get storageclass

# Ensure one supports RWX (ReadWriteMany)
```

2. Update values.yaml:
```yaml
namespace: jenkins-prod
persistence:
  storageClass: "your-rwx-storage-class"
  size: 150Gi  # 1.5x current Jenkins size
ingress:
  host: jenkins.yourdomain.com
jenkins:
  adminPassword: "SecurePassword123!"
```

3. Deploy Jenkins:
```bash
helm install jenkins ./kubernetes/helm -f values-prod.yaml
```

#### For Docker Compose:

1. Prepare environment:
```bash
# Create directory
mkdir -p jenkins-docker/jenkins_home
cd jenkins-docker

# Set permissions
sudo chown -R 1000:1000 jenkins_home
```

2. Configure .env:
```bash
cp .env.example .env
# Edit .env with your settings
```

3. Start services:
```bash
docker-compose up -d
```

### Step 3: Transfer Data

#### Transfer to Kubernetes:

1. Copy backup to a machine with kubectl:
```bash
scp jenkins-backup.zip user@k8s-host:/tmp/
```

2. Create restore job:
```yaml
# restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: jenkins-restore
  namespace: jenkins-prod
spec:
  template:
    spec:
      containers:
      - name: restore
        image: busybox
        command: ["/bin/sh", "-c"]
        args:
        - |
          cd /jenkins-home
          wget http://your-server/jenkins-backup.zip
          unzip jenkins-backup.zip
          chown -R 1000:1000 .
        volumeMounts:
        - name: jenkins-home
          mountPath: /jenkins-home
      restartPolicy: Never
      volumes:
      - name: jenkins-home
        persistentVolumeClaim:
          claimName: jenkins-shared-pvc
```

3. Run restore:
```bash
kubectl apply -f restore-job.yaml
kubectl logs -f job/jenkins-restore -n jenkins-prod
```

#### Transfer to Docker:

1. Extract backup:
```bash
cd jenkins-docker
unzip /tmp/jenkins-backup.zip -d jenkins_home/
sudo chown -R 1000:1000 jenkins_home/
```

### Step 4: Verify Migration

1. **Access new Jenkins:**
   - Get URL from ingress/service
   - Login with credentials

2. **Verification checklist:**
   - [ ] All jobs are visible
   - [ ] Build history is intact
   - [ ] Plugins are loaded
   - [ ] Credentials work
   - [ ] Agents can connect

3. **Update configurations:**
   - Jenkins URL in system settings
   - Email notification settings
   - Security realm if using LDAP/AD
   - Agent connection settings

### Step 5: Update Integrations

1. **Webhooks:**
   - GitHub/GitLab webhooks
   - Slack notifications
   - JIRA integration

2. **Build Agents:**
   - Update agent connection URL
   - Regenerate agent secrets if needed
   - Test agent connectivity

3. **External Tools:**
   - Maven/Gradle settings
   - Docker registry credentials
   - Artifact repositories

### Step 6: Cutover

1. **DNS Update:**
```bash
# Update DNS record to point to new Jenkins
jenkins.company.com → new-jenkins-ip
```

2. **Monitor logs:**
```bash
# Kubernetes
kubectl logs -f deployment/jenkins -n jenkins-prod

# Docker
docker-compose logs -f
```

3. **Enable scheduled jobs:**
   - Re-enable disabled cron triggers
   - Verify jobs run as expected

## Post-Migration Tasks

### Performance Optimization

1. **Review resource allocation:**
```yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "2000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

2. **Configure JVM options:**
```yaml
jenkins:
  javaOpts: "-Xmx4g -Xms4g -XX:+UseG1GC"
```

### Security Hardening

1. **Enable security features:**
   - CSRF protection
   - Security realm (LDAP/SAML)
   - Authorization strategy
   - Audit logging

2. **Network policies:**
```bash
kubectl apply -f kubernetes/network-policy.yaml
```

### Backup Configuration

1. **Setup automated backups:**
```bash
# Schedule daily backups
kubectl apply -f kubernetes/backup-cronjob.yaml
```

2. **Test restore procedure:**
```bash
./scripts/restore.sh
```

## Rollback Plan

If migration fails:

1. **Stop new Jenkins:**
```bash
# Kubernetes
helm uninstall jenkins

# Docker
docker-compose down
```

2. **Restore old Jenkins:**
```powershell
Start-Service Jenkins
```

3. **Revert DNS changes**

4. **Document issues for retry**

## Common Issues and Solutions

### Issue: Plugins not loading
**Solution:**
```bash
# Update plugins from CLI
java -jar jenkins-cli.jar -s http://localhost:8080 install-plugin plugin-name
```

### Issue: Agents can't connect
**Solution:**
- Check security groups/firewalls
- Verify agent port (50000) is accessible
- Regenerate agent secret

### Issue: Permissions errors
**Solution:**
```bash
# Fix permissions
kubectl exec -it jenkins-0 -n jenkins-prod -- chown -R jenkins:jenkins /var/jenkins_home
```

### Issue: Memory problems
**Solution:**
- Increase Java heap size
- Add more memory to pod/container
- Review memory-intensive plugins

## Migration Timeline

### Small Instance (<50 jobs)
- Backup: 30 minutes
- Transfer: 30 minutes
- Verification: 30 minutes
- Total: ~2 hours

### Medium Instance (50-200 jobs)
- Backup: 1 hour
- Transfer: 1 hour
- Verification: 1 hour
- Total: ~4 hours

### Large Instance (>200 jobs)
- Backup: 2-3 hours
- Transfer: 2-3 hours
- Verification: 2 hours
- Total: ~8 hours

## Support Resources

- Jenkins Documentation: https://www.jenkins.io/doc/
- Community Forums: https://community.jenkins.io/
- Stack Overflow: https://stackoverflow.com/questions/tagged/jenkins
- This Project: https://github.com/GITHUB_USERNAME/jenkins-ha-migration

## Success Criteria

Your migration is successful when:
- ✓ All jobs are accessible and functional
- ✓ Build history is preserved
- ✓ All integrations work
- ✓ Performance is equal or better
- ✓ Monitoring is operational
- ✓ Backups are automated
- ✓ Team can access and use Jenkins normally
EOF

# Create Grafana dashboard
print_status "Creating Grafana dashboard..."
cat > monitoring/grafana/dashboards/jenkins-dashboard.json << 'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": "-- Grafana --",
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 0,
            "gradientMode": "none",
            "hideFrom": {
              "tooltip": false,
              "viz": false,
              "legend": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 80
              }
            ]
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "id": 2,
      "options": {
        "tooltip": {
          "mode": "single"
        }
      },
      "pluginVersion": "8.0.0",
      "targets": [
        {
          "expr": "up{job=\"jenkins\"}",
          "refId": "A"
        }
      ],
      "title": "Jenkins Availability",
      "type": "timeseries"
    },
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 80
              }
            ]
          },
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "id": 3,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "values": false,
          "calcs": [
            "lastNotNull"
          ],
          "fields": ""
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true,
        "text": {}
      },
      "pluginVersion": "8.0.0",
      "targets": [
        {
          "expr": "rate(jenkins_job_success_total[5m]) / (rate(jenkins_job_success_total[5m]) + rate(jenkins_job_failed_total[5m])) * 100",
          "refId": "A"
        }
      ],
      "title": "Build Success Rate",
      "type": "gauge"
    }
  ],
  "refresh": "5s",
  "schemaVersion": 27,
  "style": "dark",
  "tags": ["jenkins"],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "Jenkins Dashboard",
  "uid": "jenkins-dashboard",
  "version": 0
}
EOF

# Create GitLab CI configuration
print_status "Creating GitLab CI configuration..."
cat > ci-cd/gitlab/.gitlab-ci.yml << 'EOF'
stages:
  - validate
  - test
  - build
  - security
  - deploy

variables:
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: ""
  KUBECTL_VERSION: "1.28.0"
  HELM_VERSION: "3.13.0"

.kubectl:
  image: bitnami/kubectl:${KUBECTL_VERSION}
  before_script:
    - kubectl version --client

.helm:
  image: alpine/helm:${HELM_VERSION}
  before_script:
    - helm version

# Validation Stage
validate:yaml:
  stage: validate
  image: python:3.9-slim
  before_script:
    - pip install yamllint
  script:
    - yamllint -c .yamllint.yml .
  except:
    - tags

validate:shell:
  stage: validate
  image: koalaman/shellcheck-alpine:latest
  script:
    - find . -name "*.sh" -type f | xargs shellcheck
  except:
    - tags

# Test Stage
test:helm:
  stage: test
  extends: .helm
  script:
    - helm lint kubernetes/helm
    - helm template jenkins kubernetes/helm
  except:
    - tags

test:docker:
  stage: test
  image: docker/compose:latest
  script:
    - cd docker-compose
    - docker-compose config
  except:
    - tags

# Security Stage
security:trivy:
  stage: security
  image: aquasec/trivy:latest
  script:
    - trivy fs --security-checks vuln,config --severity HIGH,CRITICAL .
  allow_failure: true
  except:
    - tags

security:checkov:
  stage: security
  image: bridgecrew/checkov:latest
  script:
    - checkov -d . --framework kubernetes,helm,dockerfile --output cli --output junitxml --output-file-path checkov-report.xml
  artifacts:
    reports:
      junit: checkov-report.xml
  allow_failure: true
  except:
    - tags

# Build Stage
build:docker:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker tag $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA $CI_REGISTRY_IMAGE:latest
    - echo $CI_REGISTRY_PASSWORD | docker login -u $CI_REGISTRY_USER --password-stdin $CI_REGISTRY
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
    - docker push $CI_REGISTRY_IMAGE:latest
  only:
    - main
    - develop

# Deploy Stage
deploy:staging:
  stage: deploy
  extends: .helm
  environment:
    name: staging
    url: https://jenkins-staging.example.com
  script:
    - helm upgrade --install jenkins-staging ./kubernetes/helm
      --namespace jenkins-staging
      --create-namespace
      --set image.tag=$CI_COMMIT_SHA
      --values kubernetes/helm/values-staging.yaml
  only:
    - develop

deploy:production:
  stage: deploy
  extends: .helm
  environment:
    name: production
    url: https://jenkins.example.com
  script:
    - helm upgrade --install jenkins ./kubernetes/helm
      --namespace jenkins-prod
      --create-namespace
      --set image.tag=$CI_COMMIT_SHA
      --values kubernetes/helm/values-prod.yaml
  only:
    - main
  when: manual
EOF

# Create Jenkinsfile for CI/CD
print_status "Creating Jenkinsfile..."
cat > ci-cd/jenkins/Jenkinsfile << 'EOF'
pipeline {
    agent any
    
    options {
        timestamps()
        timeout(time: 1, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    
    environment {
        DOCKER_REGISTRY = credentials('docker-registry')
        KUBECTL_CREDS = credentials('kubectl-config')
        SLACK_WEBHOOK = credentials('slack-webhook')
    }
    
    stages {
        stage('Validate') {
            parallel {
                stage('Lint YAML') {
                    steps {
                        sh 'yamllint -c .yamllint.yml .'
                    }
                }
                stage('Lint Shell') {
                    steps {
                        sh 'find . -name "*.sh" -type f | xargs shellcheck'
                    }
                }
                stage('Lint Helm') {
                    steps {
                        sh 'helm lint kubernetes/helm'
                    }
                }
            }
        }
        
        stage('Test') {
            parallel {
                stage('Test Helm') {
                    steps {
                        sh 'helm template jenkins kubernetes/helm'
                    }
                }
                stage('Test Docker') {
                    steps {
                        sh 'cd docker-compose && docker-compose config'
                    }
                }
            }
        }
        
        stage('Security Scan') {
            parallel {
                stage('Trivy Scan') {
                    steps {
                        sh 'trivy fs --security-checks vuln,config .'
                    }
                }
                stage('Checkov Scan') {
                    steps {
                        sh 'checkov -d . --framework kubernetes,helm,dockerfile'
                    }
                }
            }
        }
        
        stage('Build') {
            when {
                branch pattern: "(main|develop)", comparator: "REGEXP"
            }
            steps {
                script {
                    docker.withRegistry("https://${DOCKER_REGISTRY}", 'docker-creds') {
                        def customImage = docker.build("jenkins-ha:${env.BUILD_ID}")
                        customImage.push()
                        customImage.push('latest')
                    }
                }
            }
        }
        
        stage('Deploy to Staging') {
            when {
                branch 'develop'
            }
            steps {
                sh '''
                    export KUBECONFIG=$KUBECTL_CREDS
                    helm upgrade --install jenkins-staging ./kubernetes/helm \
                        --namespace jenkins-staging \
                        --create-namespace \
                        --values kubernetes/helm/values-staging.yaml
                '''
            }
        }
        
        stage('Deploy to Production') {
            when {
                branch 'main'
            }
            input {
                message "Deploy to production?"
                ok "Deploy"
            }
            steps {
                sh '''
                    export KUBECONFIG=$KUBECTL_CREDS
                    helm upgrade --install jenkins ./kubernetes/helm \
                        --namespace jenkins-prod \
                        --create-namespace \
                        --values kubernetes/helm/values-prod.yaml
                '''
            }
        }
    }
    
    post {
        success {
            sh """
                curl -X POST -H 'Content-type: application/json' \
                    --data '{"text":"✅ Build Successful: ${env.JOB_NAME} - ${env.BUILD_NUMBER}"}' \
                    ${SLACK_WEBHOOK}
            """
        }
        failure {
            sh """
                curl -X POST -H 'Content-type: application/json' \
                    --data '{"text":"❌ Build Failed: ${env.JOB_NAME} - ${env.BUILD_NUMBER}"}' \
                    ${SLACK_WEBHOOK}
            """
        }
        always {
            cleanWs()
        }
    }
}
EOF

# Create test files
print_status "Creating test files..."

# Unit tests
cat > tests/test_helm.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "Running Helm chart tests..."

# Test 1: Lint the chart
echo "Test 1: Linting Helm chart..."
helm lint kubernetes/helm
echo "✓ Helm lint passed"

# Test 2: Template rendering
echo "Test 2: Testing template rendering..."
helm template test-release kubernetes/helm > /tmp/helm-output.yaml
echo "✓ Template rendering passed"

# Test 3: Validate Kubernetes manifests
echo "Test 3: Validating Kubernetes manifests..."
kubectl apply --dry-run=client -f /tmp/helm-output.yaml
echo "✓ Kubernetes validation passed"

# Test 4: Check required values
echo "Test 4: Checking required values..."
required_values=("namespace" "image.repository" "image.tag" "persistence.size")
for value in "${required_values[@]}"; do
    if ! grep -q "$value:" kubernetes/helm/values.yaml; then
        echo "✗ Missing required value: $value"
        exit 1
    fi
done
echo "✓ Required values check passed"

echo "All Helm tests passed!"
EOF

chmod +x tests/test_helm.sh

# Integration tests
cat > tests/test_integration.sh << 'EOF'
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
EOF

chmod +x tests/test_integration.sh

# Create .yamllint.yml
print_status "Creating .yamllint.yml..."
cat > .yamllint.yml << 'EOF'
extends: default

rules:
  line-length:
    max: 120
    level: warning
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no', 'on', 'off']
  comments:
    min-spaces-from-content: 1
  indentation:
    spaces: 2
    indent-sequences: true

ignore: |
  .git/
  node_modules/
  venv/
  monitoring/grafana/dashboards/*.json
EOF

# Create backup PowerShell script for Windows
print_status "Creating Windows backup script..."
cat > scripts/backup-windows-jenkins.ps1 << 'EOF'
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
EOF

# Create project documentation
print_status "Creating project documentation..."
cat > docs/architecture.md << 'EOF'
# Architecture Overview

## System Architecture

```
                           ┌─────────────┐
                           │   Users     │
                           └──────┬──────┘
                                  │
                           ┌──────▼──────┐
                           │  Ingress/LB │
                           └──────┬──────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
              ┌─────▼─────┐              ┌─────▼─────┐
              │ Jenkins-1  │              │ Jenkins-2  │
              └─────┬─────┘              └─────┬─────┘
                    │                           │
                    └─────────────┬─────────────┘
                                  │
                           ┌──────▼──────┐
                           │Shared Volume│
                           │    (RWX)    │
                           └─────────────┘
```

## Components

### 1. Load Balancer / Ingress
- **Kubernetes**: NGINX Ingress Controller
- **Docker**: NGINX reverse proxy
- Features:
  - SSL/TLS termination
  - Request routing
  - Health checks
  - Rate limiting

### 2. Jenkins Instances
- Multiple Jenkins master instances
- Shared configuration and data
- Active-active configuration
- Session affinity for UI consistency

### 3. Shared Storage
- **Kubernetes**: PersistentVolumeClaim with RWX access
- **Docker**: Bind mount or named volume
- Contents:
  - Job configurations
  - Build history
  - Plugins
  - Credentials
  - System configuration

### 4. Monitoring Stack
- **Prometheus**: Metrics collection
- **Grafana**: Visualization
- **AlertManager**: Alert routing
- **Node Exporter**: System metrics

## High Availability Design

### Failure Scenarios

1. **Single Jenkins Instance Failure**
   - Load balancer detects unhealthy instance
   - Traffic routed to healthy instances
   - No service interruption

2. **Storage Failure**
   - Depends on storage backend redundancy
   - Recommended: Use redundant storage (RAID, distributed filesystems)

3. **Network Partition**
   - Jenkins instances continue operating
   - May have temporary inconsistencies
   - Resolves when network heals

### Data Consistency

- File-level locking for critical operations
- Build queue coordination through shared storage
- Plugin synchronization on startup

## Security Architecture

### Network Security
```
Internet → Firewall → Load Balancer → Jenkins
                           ↓
                    Internal Network
                           ↓
                    Agents/Services
```

### Authentication Flow
1. User → Load Balancer (HTTPS)
2. Load Balancer → Jenkins (HTTP)
3. Jenkins → Auth Provider (LDAP/SAML)
4. Response with session cookie

### Secret Management
- Kubernetes: Secrets API
- Docker: Environment variables or secret files
- Jenkins: Credentials plugin with encryption

## Scaling Considerations

### Horizontal Scaling
- Add more Jenkins instances
- Increase replica count in StatefulSet
- Load balancer automatically includes new instances

### Vertical Scaling
- Increase CPU/memory limits
- Adjust JVM heap size
- Monitor resource utilization

### Agent Scaling
- Dynamic agent provisioning
- Kubernetes pod templates
- Docker container agents
- Cloud provider integrations

## Disaster Recovery

### Backup Strategy
- Daily automated backups
- Retention: 30 days
- Off-site storage recommended
- Test restores monthly

### RTO/RPO Targets
- RTO (Recovery Time Objective): 4 hours
- RPO (Recovery Point Objective): 24 hours
- Can be improved with more frequent backups

### DR Procedures
1. Provision new infrastructure
2. Restore from latest backup
3. Update DNS/load balancer
4. Verify functionality
5. Resume operations
EOF

# Create troubleshooting guide
cat > docs/troubleshooting.md << 'EOF'
# Troubleshooting Guide

## Common Issues and Solutions

### Jenkins Won't Start

#### Symptoms
- Pod in CrashLoopBackOff or Error state
- Container exits immediately
- No logs available

#### Solutions
1. Check logs:
```bash
kubectl logs -f jenkins-0 -n jenkins-prod --previous
docker logs jenkins-1
```

2. Verify permissions:
```bash
kubectl exec -it jenkins-0 -n jenkins-prod -- ls -la /var/jenkins_home
```

3. Check resource limits:
```bash
kubectl describe pod jenkins-0 -n jenkins-prod
```

### Permission Denied Errors

#### Symptoms
- "Permission denied" in logs
- Cannot write to Jenkins home
- Plugin installation fails

#### Solutions
1. Fix ownership:
```bash
kubectl exec -it jenkins-0 -n jenkins-prod -- chown -R 1000:1000 /var/jenkins_home
docker exec jenkins-1 chown -R 1000:1000 /var/jenkins_home
```

2. Check PVC permissions:
```bash
kubectl get pvc -n jenkins-prod
kubectl describe pvc jenkins-shared-pvc -n jenkins-prod
```

### High Memory Usage

#### Symptoms
- Jenkins UI slow or unresponsive
- OutOfMemoryError in logs
- Container restarts frequently

#### Solutions
1. Increase heap size:
```yaml
jenkins:
  javaOpts: "-Xmx4g -Xms4g -XX:+UseG1GC"
```

2. Analyze memory usage:
```bash
kubectl exec -it jenkins-0 -n jenkins-prod -- jmap -heap 1
```

3. Review plugins:
- Disable unused plugins
- Update to latest versions
- Check for memory leaks

### Plugin Conflicts

#### Symptoms
- Jenkins fails to start after plugin update
- UI elements missing
- Errors about missing classes

#### Solutions
1. Safe mode startup:
```bash
# Add to JENKINS_OPTS
-Djenkins.install.runSetupWizard=false
```

2. Disable plugins via filesystem:
```bash
kubectl exec -it jenkins-0 -n jenkins-prod -- bash
cd /var/jenkins_home/plugins
mkdir disabled
mv problematic-plugin.jpi disabled/
```

### Build Queue Stuck

#### Symptoms
- Jobs stay in queue
- "Waiting for next available executor"
- Agents show as offline

#### Solutions
1. Check executors:
- Manage Jenkins → Manage Nodes
- Verify agent connectivity
- Check executor count

2. Review queue:
```groovy
// Script Console
import hudson.model.*
def queue = Jenkins.instance.queue
queue.items.each { 
    println "${it.task.name} - ${it.why}"
}
```

3. Clear stuck items:
```groovy
Jenkins.instance.queue.clear()
```

### Storage Issues

#### Symptoms
- "No space left on device"
- Builds failing with I/O errors
- Slow performance

#### Solutions
1. Check disk usage:
```bash
kubectl exec -it jenkins-0 -n jenkins-prod -- df -h
docker exec jenkins-1 df -h
```

2. Clean workspace:
```bash
# Delete old workspaces
find /var/jenkins_home/workspace -type d -mtime +30 -exec rm -rf {} +
```

3. Clean old builds:
```groovy
// Script Console - Delete builds older than 30 days
import jenkins.model.Jenkins
import hudson.model.Job

Jenkins.instance.getAllItems(Job.class).each { job ->
    job.builds.findAll { 
        it.timestamp.timeInMillis < System.currentTimeMillis() - 30L * 24 * 60 * 60 * 1000
    }.each { 
        it.delete()
    }
}
```

### Network Connectivity Issues

#### Symptoms
- Cannot access Jenkins UI
- Webhooks not working
- Agent connection failures

#### Solutions
1. Test connectivity:
```bash
# From outside
curl -v https://jenkins.example.com/login

# From inside cluster
kubectl run curl --image=curlimages/curl -it --rm -- curl jenkins:8080/login
```

2. Check services:
```bash
kubectl get svc -n jenkins-prod
kubectl describe svc jenkins -n jenkins-prod
```

3. Verify ingress:
```bash
kubectl get ingress -n jenkins-prod
kubectl describe ingress jenkins -n jenkins-prod
```

### SSL/TLS Issues

#### Symptoms
- Certificate errors in browser
- "SSL handshake failed"
- Mixed content warnings

#### Solutions
1. Verify certificate:
```bash
openssl s_client -connect jenkins.example.com:443 -servername jenkins.example.com
```

2. Check ingress configuration:
```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

3. Update Jenkins URL:
- Manage Jenkins → Configure System
- Set Jenkins URL to https://

## Performance Tuning

### JVM Tuning
```bash
# Recommended JVM options
-Xmx4g
-Xms4g
-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:+DisableExplicitGC
-XX:+UnlockDiagnosticVMOptions
-XX:+UnlockExperimentalVMOptions
```

### Database Optimization
- Use external database for large instances
- Regular VACUUM for PostgreSQL
- Optimize MySQL buffer pool

### Caching
- Enable browser caching
- Use CDN for static assets
- Configure reverse proxy caching

## Debug Commands

### Kubernetes
```bash
# Get all resources
kubectl get all -n jenkins-prod

# Describe pod
kubectl describe pod jenkins-0 -n jenkins-prod

# Get events
kubectl get events -n jenkins-prod --sort-by='.lastTimestamp'

# Execute commands
kubectl exec -it jenkins-0 -n jenkins-prod -- bash

# Port forward for debugging
kubectl port-forward jenkins-0 8080:8080 -n jenkins-prod

# Check resource usage
kubectl top pod -n jenkins-prod
```

### Docker
```bash
# List containers
docker ps -a

# Inspect container
docker inspect jenkins-1

# View logs
docker logs --tail 100 -f jenkins-1

# Execute commands
docker exec -it jenkins-1 bash

# Check resource usage
docker stats jenkins-1
```

### Jenkins CLI
```bash
# Download CLI
wget http://localhost:8080/jnlpJars/jenkins-cli.jar

# List jobs
java -jar jenkins-cli.jar -s http://localhost:8080 list-jobs

# Reload configuration
java -jar jenkins-cli.jar -s http://localhost:8080 reload-configuration

# Safe restart
java -jar jenkins-cli.jar -s http://localhost:8080 safe-restart
```

## Getting Help

1. Check Jenkins logs first
2. Search Jenkins documentation
3. Check community forums
4. Review GitHub issues
5. Contact support team

Remember to always:
- Backup before making changes
- Test in staging first
- Document what you've tried
- Include error messages and logs when asking for help
EOF

# Create final setup script
print_status "Creating setup completion script..."
cat > setup.sh << 'EOF'
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
EOF

chmod +x setup.sh

# Initialize git repository
print_status "Initializing Git repository..."
git add .
git commit -m "Initial commit: Jenkins HA Migration Project" || true

# Final summary
print_status "Setup complete!"
echo ""
echo "======================================"
echo "Jenkins HA Migration Project Created!"
echo "======================================"
echo ""
echo "Project location: $(pwd)"
echo ""
echo "Next steps:"
echo "1. Review all configuration files"
echo "2. Update GitHub username and email in git config"
echo "3. Run './setup.sh' to complete setup"
echo "4. Create GitHub repository and push:"
echo "   git remote add origin https://github.com/${GITHUB_USERNAME}/${PROJECT_NAME}.git"
echo "   git push -u origin main"
echo ""
echo "Key files to configure:"
echo "- kubernetes/helm/values.yaml (for Kubernetes)"
echo "- .env (for Docker Compose)"
echo "- monitoring/prometheus/prometheus.yml"
echo "- ci-cd/github/workflows/ci.yml"
echo ""
echo "Documentation:"
echo "- README.md - Main documentation"
echo "- docs/configuration.md - Configuration guide"
echo "- docs/migration-guide.md - Migration instructions"
echo "- docs/monitoring.md - Monitoring setup"
echo "- docs/troubleshooting.md - Troubleshooting guide"
echo ""
echo "Happy migrating!"