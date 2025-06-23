# Monitoring Guide

This guide covers setting up comprehensive monitoring for your Jenkins deployment.

## Overview

The monitoring stack includes:
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **AlertManager**: Alert routing and management
- **Node Exporter**: System metrics

## Quick Start

### For Docker Compose

1. Start the monitoring stack:
```bash
cd monitoring
docker-compose up -d
```

2. Access services:
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (admin/admin)
- AlertManager: http://localhost:9093

### For Kubernetes

1. Install Prometheus Operator:
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring
```

2. Configure ServiceMonitor for Jenkins:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: jenkins
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: jenkins
  endpoints:
  - port: http
    path: /prometheus
    interval: 30s
```

## Jenkins Metrics

### Available Metrics

Jenkins exposes various metrics via the Prometheus plugin:

**System Metrics:**
- `jenkins_up`: Jenkins availability
- `jenkins_cpu_usage`: CPU usage
- `jenkins_memory_usage`: Memory usage
- `jenkins_disk_usage`: Disk usage

**Job Metrics:**
- `jenkins_job_duration_seconds`: Job execution time
- `jenkins_job_success_total`: Successful jobs
- `jenkins_job_failed_total`: Failed jobs
- `jenkins_job_aborted_total`: Aborted jobs

**Queue Metrics:**
- `jenkins_queue_size`: Current queue size
- `jenkins_queue_blocked`: Blocked items
- `jenkins_queue_buildable`: Buildable items

**Node Metrics:**
- `jenkins_node_online`: Node status
- `jenkins_node_busy_executors`: Busy executors
- `jenkins_node_idle_executors`: Idle executors

### Custom Metrics

Add custom metrics in your Jenkinsfile:
```groovy
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                script {
                    // Record custom metric
                    currentBuild.setCustomMetric('custom_metric', 42)
                }
            }
        }
    }
}
```

## Grafana Dashboards

### Import Jenkins Dashboard

1. Log in to Grafana
2. Go to Dashboards → Import
3. Enter dashboard ID: `9964` (Jenkins Performance and Health Overview)
4. Select Prometheus data source
5. Click Import

### Custom Dashboard

Create a custom dashboard with these panels:

**Jenkins Health:**
```promql
up{job="jenkins"}
```

**Build Success Rate:**
```promql
rate(jenkins_job_success_total[5m]) / 
(rate(jenkins_job_success_total[5m]) + rate(jenkins_job_failed_total[5m])) * 100
```

**Average Build Duration:**
```promql
rate(jenkins_job_duration_seconds_sum[5m]) / 
rate(jenkins_job_duration_seconds_count[5m])
```

**Queue Size Over Time:**
```promql
jenkins_queue_size
```

## Alerting

### Alert Rules

Create `monitoring/prometheus/alerts/jenkins.yml`:

```yaml
groups:
  - name: jenkins
    interval: 30s
    rules:
      # Jenkins Down
      - alert: JenkinsDown
        expr: up{job="jenkins"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Jenkins is down"
          description: "Jenkins instance {{ $labels.instance }} is down"

      # High Memory Usage
      - alert: JenkinsHighMemory
        expr: jenkins_memory_usage > 80
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage"
          description: "Jenkins memory usage is {{ $value }}%"

      # High Queue Size
      - alert: JenkinsHighQueueSize
        expr: jenkins_queue_size > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High build queue"
          description: "Jenkins queue size is {{ $value }}"

      # No Idle Executors
      - alert: JenkinsNoIdleExecutors
        expr: sum(jenkins_node_idle_executors) == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "No idle executors"
          description: "All Jenkins executors are busy"

      # Disk Space Low
      - alert: JenkinsDiskSpaceLow
        expr: jenkins_disk_usage > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Low disk space"
          description: "Jenkins disk usage is {{ $value }}%"
```

### AlertManager Configuration

Configure `monitoring/alertmanager/alertmanager.yml`:

```yaml
global:
  resolve_timeout: 5m
  smtp_from: 'jenkins@example.com'
  smtp_smarthost: 'smtp.example.com:587'
  smtp_auth_username: 'jenkins@example.com'
  smtp_auth_password: 'password'

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
group_interval: 10s
  repeat_interval: 1h
  receiver: 'team-emails'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty'
    - match:
        severity: warning
      receiver: 'slack'

receivers:
  - name: 'team-emails'
    email_configs:
      - to: 'team@example.com'
        headers:
          Subject: 'Jenkins Alert: {{ .GroupLabels.alertname }}'

  - name: 'slack'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK_URL'
        channel: '#jenkins-alerts'
        title: 'Jenkins Alert'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'

  - name: 'pagerduty'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_SERVICE_KEY'
```

## Log Aggregation

### Using ELK Stack

1. Configure Jenkins to send logs to Elasticsearch:
```groovy
pipeline {
    agent any
    options {
        timestamps()
        ansiColor('xterm')
    }
    stages {
        stage('Build') {
            steps {
                echo 'Building...'
            }
        }
    }
    post {
        always {
            // Send logs to Elasticsearch
            logstashSend failBuild: false, maxLines: 1000
        }
    }
}
```

2. Create Logstash pipeline:
```ruby
input {
  tcp {
    port => 5000
    codec => json
  }
}

filter {
  if [type] == "jenkins" {
    mutate {
      add_field => { "[@metadata][target_index]" => "jenkins-%{+YYYY.MM.dd}" }
    }
  }
}

output {
  elasticsearch {
    hosts => ["elasticsearch:9200"]
    index => "%{[@metadata][target_index]}"
  }
}
```

### Using Loki

1. Install Loki plugin in Jenkins
2. Configure Loki URL in Jenkins system configuration
3. Query logs in Grafana:
```logql
{job="jenkins"} |~ "ERROR|WARN"
```

## Performance Tuning

### Metrics Retention

Configure Prometheus retention:
```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: 50GB
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
```

### Dashboard Optimization

1. Use recording rules for frequently used queries:
```yaml
groups:
  - name: jenkins_recording
    interval: 30s
    rules:
      - record: jenkins:build_success_rate:5m
        expr: |
          rate(jenkins_job_success_total[5m]) / 
          (rate(jenkins_job_success_total[5m]) + rate(jenkins_job_failed_total[5m]))
```

2. Optimize panel queries:
   - Use appropriate time ranges
   - Limit cardinality
   - Use recording rules for complex queries

## Troubleshooting

### No Metrics Available

1. Check Jenkins Prometheus plugin:
```bash
curl http://jenkins:8080/prometheus
```

2. Verify Prometheus configuration:
```bash
curl http://prometheus:9090/api/v1/targets
```

3. Check ServiceMonitor (Kubernetes):
```bash
kubectl get servicemonitor -n monitoring
kubectl describe servicemonitor jenkins -n monitoring
```

### High Cardinality Issues

Identify high cardinality metrics:
```promql
topk(10, count by (__name__)({__name__=~"jenkins.*"}))
```

Solutions:
- Drop unnecessary labels
- Use recording rules
- Adjust scrape interval

### Missing Dashboards

1. Check Grafana datasource:
   - Settings → Data Sources → Prometheus
   - Test connection

2. Verify dashboard variables:
   - Dashboard Settings → Variables
   - Ensure queries return data

## Best Practices

1. **Alert Fatigue Prevention:**
   - Set appropriate thresholds
   - Use alert grouping
   - Implement proper routing

2. **Dashboard Design:**
   - Group related metrics
   - Use consistent color schemes
   - Include documentation panels

3. **Metric Naming:**
   - Follow Prometheus conventions
   - Use descriptive names
   - Include units in metric names

4. **Resource Planning:**
   - Monitor Prometheus resource usage
   - Plan for metric growth
   - Implement retention policies

5. **Security:**
   - Secure Prometheus endpoints
   - Use authentication for Grafana
   - Encrypt metric data in transit
EOF
