# Configuration Guide

This guide covers all configuration options for both Kubernetes and Docker Compose deployments.

## Kubernetes Configuration

### values.yaml Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace | `jenkins-prod` |
| `replicaCount` | Number of Jenkins replicas | `2` |
| `image.repository` | Jenkins Docker image | `jenkins/jenkins` |
| `image.tag` | Jenkins version | `2.426.3-lts-jdk11` |
| `jenkins.adminUser` | Admin username | `admin` |
| `jenkins.adminPassword` | Admin password | `ChangeMe123!` |
| `persistence.storageClass` | Storage class for PVC | `""` |
| `persistence.size` | PVC size | `100Gi` |
| `ingress.enabled` | Enable ingress | `true` |
| `ingress.host` | Jenkins hostname | `jenkins.example.com` |

### Storage Configuration

For high availability, you need a storage class that supports ReadWriteMany (RWX):
- **AWS**: Use EFS CSI driver
- **Azure**: Use Azure Files
- **GCP**: Use Filestore CSI driver
- **On-premise**: Use NFS provisioner

Example NFS storage class:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: nfs-client-provisioner
parameters:
  archiveOnDelete: "true"
```

### TLS/SSL Configuration

1. Create TLS secret:
```bash
kubectl create secret tls jenkins-tls \
  --cert=path/to/cert.pem \
  --key=path/to/key.pem \
  -n jenkins-prod
```

2. Update `values.yaml`:
```yaml
ingress:
  tls:
    enabled: true
    secretName: jenkins-tls
```

## Docker Compose Configuration

### Environment Variables

Create `.env` file from `.env.example`:
```bash
cp .env.example .env
```

Key variables:
- `JENKINS_ADMIN_USER`: Admin username
- `JENKINS_ADMIN_PASSWORD`: Admin password
- `JENKINS_HOME_PATH`: Path to Jenkins home
- `JENKINS_MEMORY_LIMIT`: Java heap size
- `COMPOSE_PROJECT_NAME`: Docker Compose project name

### Resource Sizing

Small (< 50 jobs):
```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "1000m"
```

Medium (50-200 jobs):
```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

Large (> 200 jobs):
```yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "2000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

## Monitoring Configuration

### Prometheus Metrics

Jenkins exposes metrics at `/prometheus` endpoint. Configure scraping:

```yaml
scrape_configs:
  - job_name: 'jenkins'
    metrics_path: '/prometheus'
    static_configs:
      - targets: ['jenkins:8080']
```

### Key Metrics to Monitor

- `jenkins_job_duration_seconds`: Job execution time
- `jenkins_builds_total`: Total builds
- `jenkins_node_online`: Node availability
- `jenkins_queue_size`: Build queue size
- `jenkins_plugins_active`: Active plugins

### Alerting Rules

Example alert for high queue size:
```yaml
groups:
  - name: jenkins
    rules:
      - alert: JenkinsHighQueueSize
        expr: jenkins_queue_size > 10
        for: 5m
        annotations:
          summary: "High Jenkins queue size"
          description: "Jenkins queue size is {{ $value }}"
```

## Backup Configuration

### Automated Backups

For Kubernetes, create a CronJob:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: jenkins-backup
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: jenkins/jenkins:lts
            command: ["/bin/bash", "-c"]
            args:
              - |
                tar -czf /backup/jenkins-$(date +%Y%m%d).tar.gz \
                  -C /var/jenkins_home \
                  --exclude='workspace/*' \
                  --exclude='caches/*' \
                  jobs users secrets plugins *.xml
```

### What to Backup

Essential:
- `jobs/` - Job configurations
- `users/` - User settings
- `secrets/` - Credentials
- `*.xml` - Global configs
- `plugins/` - Installed plugins

Optional:
- `builds/` - Build history
- `fingerprints/` - Artifact tracking
- `nodes/` - Agent configurations

## Troubleshooting

### Common Issues

1. **Pods not starting**: Check PVC binding
2. **Permission denied**: Verify UID/GID (1000:1000)
3. **Plugin issues**: Start with minimal plugins
4. **Memory issues**: Increase Java heap size
5. **Slow performance**: Check resource limits

### Debug Commands

Kubernetes:
```bash
kubectl logs -f jenkins-0 -n jenkins-prod
kubectl describe pod jenkins-0 -n jenkins-prod
kubectl exec -it jenkins-0 -n jenkins-prod -- bash
```

Docker Compose:
```bash
docker-compose logs -f jenkins-1
docker exec -it jenkins-1 bash
docker-compose ps
```
