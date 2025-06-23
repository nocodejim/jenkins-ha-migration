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
