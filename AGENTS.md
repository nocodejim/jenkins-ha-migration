# Agent Instructions for Demo Scripts

This document provides guidance for AI agents (and humans) working with the demo scripts: `demo-docker.sh`, `demo-k8s.sh`, and `demo-reset.sh`.

## Overview

These scripts are designed to provide a quick and foolproof way to set up and tear down a Jenkins High Availability (HA) demonstration environment using either Docker Compose or Kubernetes (via Helm).

- `demo-docker.sh`: Deploys Jenkins HA, Nginx (as a load balancer), and a monitoring stack (Prometheus, Grafana) using Docker Compose. It also creates a sample Jenkins job.
- `demo-k8s.sh`: Deploys Jenkins HA to a Kubernetes cluster using the provided Helm chart (`kubernetes/helm/`). It sets up Ingress and creates a sample Jenkins job. Monitoring relies on a `ServiceMonitor` object, expecting a Prometheus Operator in the cluster.
- `demo-reset.sh`: Cleans up resources created by both `demo-docker.sh` and `demo-k8s.sh`.

## Key Design Principles & Conventions

1.  **Idempotency**: Scripts should be runnable multiple times with the same outcome. Cleanup functions are generally called before deployment actions.
2.  **Error Handling**: Scripts use `set -euo pipefail` for robustness. Errors should be reported clearly.
3.  **User Interaction**: Destructive operations in `demo-reset.sh` (and namespace deletion in `demo-k8s.sh` cleanup) require user confirmation.
4.  **Configuration via `.env`**:
    *   Scripts can load configuration variables (credentials, names, paths) from a `.env` file located in the repository root.
    *   Defaults are provided within the scripts if `.env` is not present or a variable is missing. Refer to `.env.example` for common variables.
    *   `demo-docker.sh` uses `COMPOSE_PROJECT_NAME` from `.env` for the main Jenkins stack.
    *   `demo-k8s.sh` uses `K8S_NAMESPACE`, `HELM_RELEASE_NAME`, `JENKINS_ADMIN_USER_K8S`, `JENKINS_ADMIN_PASSWORD_K8S`, `JENKINS_INGRESS_HOST_K8S`.
5.  **Modularity**: Scripts are broken down into functions for clarity and reusability.
6.  **Leveraging Existing Infrastructure**:
    *   The scripts heavily rely on the existing `docker-compose/` configurations and the `kubernetes/helm/` chart. Changes to these underlying configurations may require updates to the demo scripts.
    *   `demo-docker.sh` uses the `setup.sh` script to generate self-signed certificates and prepare directories for the Docker deployment.

## Specific Script Notes

### `demo-docker.sh`

*   **Network Configuration**:
    *   The main Jenkins stack (from `docker-compose/docker-compose.yml`) creates a network (e.g., `yourproject_jenkins-net`).
    *   The monitoring stack (Prometheus) is deployed using a temporary, modified Docker Compose file (`docker-compose.monitoring.jenkins-scrape.yml`) that connects Prometheus to this Jenkins network.
    *   The script dynamically determines the Jenkins network name based on `COMPOSE_PROJECT_NAME` (from `.env`) or the directory name of the main compose file.
    *   The monitoring stack itself is launched with a dedicated project name (`jenkins-monitoring`) to avoid conflicts.
*   **Prometheus Configuration**: A temporary `prometheus.jenkins-scrape.yml` is generated to ensure Prometheus scrapes the `jenkins-1:8080` and `jenkins-2:8080` targets on their shared network.
*   **Jenkins Job Creation**: Uses `curl` and the Jenkins API with admin credentials and a CSRF crumb. The job XML is embedded in the script.
*   **Nginx & SSL**: Relies on `setup.sh` to generate self-signed SSL certificates. Access is typically via `https://localhost` or `https://jenkins.local` (if `/etc/hosts` is configured).

### `demo-k8s.sh`

*   **Helm Chart**: Uses the chart located at `kubernetes/helm/`.
*   **Namespace & Release**: Uses configurable namespace and Helm release names (defaults to `jenkins-demo` and `jenkins-demo` respectively).
*   **Access URL**: Attempts to determine the Jenkins URL by checking Ingress, then LoadBalancer service, then NodePort service. Users may need to configure DNS or `/etc/hosts` for Ingress.
*   **Monitoring**: The Helm chart creates a `ServiceMonitor`. This requires a Prometheus Operator (e.g., from `kube-prometheus-stack`) to be installed and configured in the Kubernetes cluster to scrape the metrics. The demo script *does not* deploy Prometheus Operator.
*   **Jenkins Job Creation**: Similar to `demo-docker.sh`, uses `curl` and the Jenkins API.

### `demo-reset.sh`

*   **Selectivity**: Allows users to choose whether to reset the Docker environment, the Kubernetes environment, or both.
*   **Caution**: Prompts for confirmation for actions like deleting Docker volumes, K8s namespaces, or running `docker system prune`.
*   **Dependency on Naming**: Relies on the default names/paths used in `demo-docker.sh` and `demo-k8s.sh` (or those specified in `.env`) to find and clean up resources.

## Maintaining and Extending

*   **Updating Jenkins/Tool Versions**:
    *   For Docker: Update `JENKINS_VERSION` in `docker-compose/docker-compose.yml` or via the `.env` file. Update image tags in `docker-compose/monitoring/docker-compose.yml` as needed.
    *   For Kubernetes: Update `appVersion` in `kubernetes/helm/Chart.yaml` and image tags in `kubernetes/helm/values.yaml`.
    *   The demo scripts themselves generally don't hardcode versions but rely on the underlying compose/chart files.
*   **Changing Sample Jenkins Job**: Modify the embedded XML string in `create_sample_jenkins_job` (in `demo-docker.sh`) or `create_sample_job_k8s` (in `demo-k8s.sh`).
*   **Modifying Helm Chart Values**: If `kubernetes/helm/values.yaml` defaults are changed significantly, review the `--set` parameters in `deploy_jenkins_k8s` within `demo-k8s.sh` to ensure they are still appropriate or override new defaults as needed.
*   **Network Changes (Docker)**: If `docker-compose/docker-compose.yml` network configurations change, the logic in `prepare_monitoring_configs` within `demo-docker.sh` might need adjustment to ensure Prometheus can still connect to the Jenkins network.
*   **Testing**: After any changes, manually run through the deployment and reset scripts for both Docker and Kubernetes environments to ensure they still function as expected.

## Programmatic Checks (Future Consideration)

While not currently implemented, future enhancements could include programmatic checks run after script execution to verify deployment integrity. For example:

*   A small test script that uses `curl` to hit Jenkins/Prometheus/Grafana endpoints and check for expected content or status codes.
*   For Kubernetes, `kubectl` commands to verify pod counts, readiness, and service exposure.
*   A Jenkins CLI command or API call to verify the sample job was created and can be triggered.

If such checks are added, they should be documented here and integrated into the demo scripts or called by an overarching test script.
The agent responsible for changes MUST ensure these checks pass.
