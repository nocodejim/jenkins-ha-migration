# Troubleshooting the Monitoring Stack

This guide provides steps to diagnose and resolve common issues with the Prometheus, Grafana, and Alertmanager monitoring stack defined in this directory.

## General Checks

1.  **Run the Validation Script**:
    The first step should always be to run the validation script. It checks several common failure points.
    ```bash
    # From the repository root
    ./scripts/validate-monitoring.sh
    ```
    Review the output for specific failures.

2.  **Check Docker Container Status**:
    Ensure all containers are up and running.
    ```bash
    # From the monitoring directory
    docker-compose ps

    # Or from the repository root
    docker-compose -f monitoring/docker-compose.yml ps
    ```
    If any containers are not `Up` or are restarting, check their logs.

3.  **Check Container Logs**:
    Replace `<service_name>` with the name of the problematic service (e.g., `prometheus`, `grafana`, `jenkins`).
    ```bash
    # From the monitoring directory
    docker-compose logs <service_name>

    # For more logs (e.g., last 100 lines and follow)
    docker-compose logs --tail=100 -f <service_name>
    ```

4.  **Network Issues**:
    *   **Verify Network Existence**: The `docker-compose.yml` defines a bridge network named `monitoring_monitoring` (default naming `<projectdir>_<networkname>`). Ensure it exists:
        ```bash
        docker network ls | grep monitoring_monitoring
        ```
    *   **Inspect Network**: See which containers are attached.
        ```bash
        docker network inspect monitoring_monitoring
        ```
    *   **Container Connectivity**: Test if containers can reach each other by name. For example, from the Prometheus container, try to reach Jenkins:
        ```bash
        # From the monitoring directory
        docker-compose exec prometheus apk add --no-cache curl # If curl is not available
        docker-compose exec prometheus curl http://jenkins:8080/jenkins/prometheus
        docker-compose exec prometheus curl http://alertmanager:9093
        docker-compose exec grafana wget http://prometheus:9090 # If wget is available, or use curl
        ```

## Prometheus Issues

1.  **Prometheus UI**:
    Access Prometheus at `http://localhost:9090`.

2.  **Targets Page**:
    Go to `Status -> Targets` in the Prometheus UI.
    *   All targets (`jenkins`, `prometheus`, `node-exporter`, `alertmanager`) should be `UP`.
    *   If a target is `DOWN`, check the `Error` column for details. Common issues:
        *   Network connectivity (see General Checks).
        *   The target service is not exposing metrics on the configured path.
        *   Incorrect scrape configuration in `monitoring/prometheus/prometheus.yml`.

3.  **Jenkins Scrape Issues**:
    *   **Jenkins Metrics Endpoint**: Ensure Jenkins is exposing metrics at `http://jenkins:8080/jenkins/prometheus`. You can verify this from within the Prometheus container (see Network Issues) or by accessing Jenkins directly if you've exposed its port.
        The `JENKINS_OPTS` in `docker-compose.yml` for the Jenkins service is responsible for enabling the Prometheus plugin and setting the context path.
    *   **Prometheus Configuration**: Double-check the `job_name: 'jenkins'` configuration in `monitoring/prometheus/prometheus.yml`, especially `metrics_path` and the target address.

4.  **"Context deadline exceeded" or "Connection refused" errors for targets**:
    *   This usually means Prometheus cannot reach the target container at the specified address/port.
    *   Verify the target container is running and healthy.
    *   Verify they are on the same Docker network (`monitoring_monitoring`).
    *   Check for firewalls if your Docker host has them enabled, though less common for container-to-container communication on a bridge network.

## Grafana Issues

1.  **Grafana UI**:
    Access Grafana at `http://localhost:3000`. Default login is `admin`/`admin`.

2.  **Datasource Configuration**:
    *   Go to `Configuration (gear icon) -> Data Sources`.
    *   You should see the `Prometheus` datasource.
    *   Click on it and then `Save & Test`. It should report "Data source is working".
    *   If not, common issues:
        *   Grafana cannot reach Prometheus at `http://prometheus:9090`. Check network connectivity between Grafana and Prometheus containers.
        *   Incorrect URL in `monitoring/grafana/provisioning/datasources/prometheus.yml`.

3.  **Dashboard Issues**:
    *   **Dashboards Not Loading**: If the "Jenkins Overview" dashboard (or others) is missing:
        *   Check Grafana logs for errors related to dashboard provisioning.
        *   Verify the dashboard JSON files in `monitoring/grafana/dashboards/` are valid.
        *   Verify the dashboard provisioning configuration in `monitoring/grafana/provisioning/dashboards/default.yml` is correct and the path points to where the dashboards are mounted in the container (`/var/lib/grafana/dashboards`).
        *   Verify volume mounts in `docker-compose.yml` for Grafana provisioning and dashboards are correct.
    *   **Dashboards Showing Errors (e.g., "No data")**:
        *   Ensure the Prometheus datasource is working.
        *   Ensure Prometheus is successfully scraping metrics from Jenkins (and other targets).
        *   Check the time range in Grafana.
        *   Inspect panel queries to ensure they are valid PromQL and metrics exist.

## Alertmanager Issues

1.  **Alertmanager UI**:
    Access Alertmanager at `http://localhost:9093` (if you want to inspect its state, though it has a minimal UI).

2.  **Prometheus Configuration for Alertmanager**:
    In `monitoring/prometheus/prometheus.yml`, ensure the `alertmanagers` section under `alerting` correctly points to `alertmanager:9093`.
    ```yaml
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
                - alertmanager:9093
    ```

3.  **Alertmanager Configuration**:
    Check `monitoring/alertmanager/alertmanager.yml` for syntax errors. Alertmanager logs will indicate issues with loading its configuration.

4.  **Alerts Not Firing/Notifying**:
    *   Verify alerts are defined in Prometheus (e.g., in `monitoring/prometheus/alerts/*.yml` - currently this directory is empty, so no alerts will fire).
    *   In Prometheus UI, go to `Alerts` to see the state of configured alerts (pending, firing).
    *   Check Alertmanager logs for errors related to processing alerts or sending notifications.
    *   The default `alertmanager.yml` has a dummy webhook. For actual notifications, configure a valid receiver (email, Slack, etc.).

## Jenkins Issues (as a Prometheus target)

1.  **Jenkins UI**:
    Access Jenkins at `http://localhost:8080/jenkins/`.

2.  **Prometheus Plugin**:
    *   Ensure the Prometheus plugin is installed and active. The `JENKINS_OPTS` in `docker-compose.yml` should handle this:
      `--plugin=prometheus:2.0.7`
    *   Metrics should be available at `/jenkins/prometheus` (due to `--prefix=/jenkins`). Visit `http://localhost:8080/jenkins/prometheus` in your browser. You should see text-based metrics. If not, the plugin is not configured correctly or not working.
    *   Check Jenkins logs for errors related to the Prometheus plugin.

## Docker Compose Specifics

1.  **Recreating Containers**:
    If you make changes to `docker-compose.yml` or configuration files, you often need to recreate the containers:
    ```bash
    # From the monitoring directory
    docker-compose down
    docker-compose up -d --build # Use --build if you changed Dockerfile or image specific things
    ```
    For config file changes that are volume-mounted, often a restart of the specific service is enough:
    ```bash
    docker-compose restart <service_name>
    ```

2.  **Volume Issues**:
    *   Ensure paths in volume mounts in `docker-compose.yml` are correct relative to the `docker-compose.yml` file itself.
    *   If you see permission errors in logs related to volumes, it might be a Docker Desktop or Linux permissions issue on the host path.

By following these steps, you should be able to identify and resolve most common issues with the monitoring stack.Tool output for `create_file_with_block`:
