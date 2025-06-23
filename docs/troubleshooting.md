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
