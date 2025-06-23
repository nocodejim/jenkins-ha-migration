#!/bin/bash

# Strict mode
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# --- Helper Functions ---
info() {
    echo -e "${GREEN}[INFO] ${1}${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] ${1}${NC}"
}

error() {
    echo -e "${RED}[ERROR] ${1}${NC}" >&2
}

confirm() {
    local prompt="$1 (y/N): "
    local response
    read -r -p "$(echo -e "${YELLOW}${prompt}${NC}")" response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0 # Yes
    else
        return 1 # No or anything else
    fi
}

# --- Docker Demo Reset Logic ---
# Variables that might be set in .env, with defaults from demo-docker.sh
DOCKER_JENKINS_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose/docker-compose.yml"
DOCKER_MONITORING_COMPOSE_ORIGINAL="${SCRIPT_DIR}/docker-compose/monitoring/docker-compose.yml"
DOCKER_MONITORING_COMPOSE_TEMP="${SCRIPT_DIR}/docker-compose/monitoring/docker-compose.monitoring.jenkins-scrape.yml"
DOCKER_PROMETHEUS_CONFIG_TEMP="${SCRIPT_DIR}/docker-compose/monitoring/prometheus/prometheus.jenkins-scrape.yml"
DOCKER_JENKINS_HOME_PATH="${SCRIPT_DIR}/docker-compose/jenkins_home" # As used in demo-docker.sh
DOCKER_CERTS_PATH="${SCRIPT_DIR}/docker-compose/certs" # As used by setup.sh

reset_docker_demo() {
    info "--- Starting Docker Demo Reset ---"

    # Load COMPOSE_PROJECT_NAME from .env if it exists, as demo-docker.sh uses it.
    local docker_project_name=""
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        set +u
        # shellcheck source=.env
        source "${SCRIPT_DIR}/.env"
        docker_project_name="${COMPOSE_PROJECT_NAME:-}" # Use COMPOSE_PROJECT_NAME from .env
        set -u
    fi

    local jenkins_compose_cmd="docker-compose"
    if [ -n "$docker_project_name" ]; then
        jenkins_compose_cmd="docker-compose -p ${docker_project_name}"
    fi
    jenkins_compose_cmd="${jenkins_compose_cmd} -f ${DOCKER_JENKINS_COMPOSE_FILE}"

    info "Stopping and removing Jenkins services..."
    if [ -f "$DOCKER_JENKINS_COMPOSE_FILE" ]; then
        ${jenkins_compose_cmd} down -v --remove-orphans 2>/dev/null || warn "Failed to run 'docker-compose down' for Jenkins, or already down."
    else
        warn "Jenkins Docker Compose file not found: ${DOCKER_JENKINS_COMPOSE_FILE}"
    fi

    info "Stopping and removing original monitoring services..."
    if [ -f "$DOCKER_MONITORING_COMPOSE_ORIGINAL" ]; then
        # Monitoring stack in demo-docker.sh uses a fixed project name 'jenkins-monitoring'
        docker-compose -p jenkins-monitoring -f "$DOCKER_MONITORING_COMPOSE_ORIGINAL" down -v --remove-orphans 2>/dev/null || \
        docker-compose -f "$DOCKER_MONITORING_COMPOSE_ORIGINAL" down -v --remove-orphans 2>/dev/null || \
        warn "Failed to run 'docker-compose down' for original monitoring, or already down."
    else
        warn "Original monitoring Docker Compose file not found: ${DOCKER_MONITORING_COMPOSE_ORIGINAL}"
    fi

    info "Stopping and removing temporary monitoring services (if any)..."
    if [ -f "$DOCKER_MONITORING_COMPOSE_TEMP" ]; then
         docker-compose -p jenkins-monitoring -f "$DOCKER_MONITORING_COMPOSE_TEMP" down -v --remove-orphans 2>/dev/null || \
         warn "Failed to run 'docker-compose down' for temporary monitoring, or already down."
    else
        info "Temporary monitoring compose file not found, skipping."
    fi

    info "Removing temporary configuration files..."
    rm -f "${DOCKER_MONITORING_COMPOSE_TEMP}" "${DOCKER_PROMETHEUS_CONFIG_TEMP}"
    info "Temporary files removed."

    if confirm "Delete Docker volume directory '${DOCKER_JENKINS_HOME_PATH}'?"; then
        if [ -d "${DOCKER_JENKINS_HOME_PATH}" ]; then
            info "Deleting Jenkins home directory: ${DOCKER_JENKINS_HOME_PATH}"
            # This directory might be owned by user 1000 if setup.sh ran chown.
            # sudo might be required if the current user doesn't have perms.
            if rm -rf "${DOCKER_JENKINS_HOME_PATH}"; then
                info "Deleted ${DOCKER_JENKINS_HOME_PATH}."
            else
                warn "Failed to delete ${DOCKER_JENKINS_HOME_PATH}. Manual deletion or sudo might be required."
            fi
        else
            info "Jenkins home directory not found: ${DOCKER_JENKINS_HOME_PATH}"
        fi
    fi

    if confirm "Delete Docker certs directory '${DOCKER_CERTS_PATH}' (contains self-signed certs)?"; then
        if [ -d "${DOCKER_CERTS_PATH}" ]; then
            info "Deleting certs directory: ${DOCKER_CERTS_PATH}"
            if rm -rf "${DOCKER_CERTS_PATH}"; then
                info "Deleted ${DOCKER_CERTS_PATH}."
            else
                warn "Failed to delete ${DOCKER_CERTS_PATH}. Manual deletion might be required."
            fi
        else
            info "Certs directory not found: ${DOCKER_CERTS_PATH}"
        fi
    fi

    if confirm "Run 'docker system prune -af --volumes'? CAUTION: This removes ALL unused Docker data (containers, networks, volumes, images)."; then
        info "Running 'docker system prune -af --volumes'..."
        docker system prune -af --volumes || error "Docker system prune command failed."
        info "Docker system prune complete."
    else
        info "Skipping 'docker system prune'."
    fi

    info "--- Docker Demo Reset Complete ---"
}

# --- Kubernetes Demo Reset Logic ---
# Variables that might be set in .env, with defaults from demo-k8s.sh
K8S_NAMESPACE_RESET="${K8S_NAMESPACE:-jenkins-demo}" # Default from demo-k8s.sh
HELM_RELEASE_NAME_RESET="${HELM_RELEASE_NAME:-jenkins-demo}" # Default from demo-k8s.sh

reset_kubernetes_demo() {
    info "--- Starting Kubernetes Demo Reset ---"

    command -v kubectl >/dev/null 2>&1 || { warn "kubectl not found. Skipping Kubernetes reset."; return; }
    command -v helm >/dev/null 2>&1 || { warn "Helm not found. Skipping Kubernetes reset."; return; }

    # Load K8s specific vars from .env if it exists, to get the correct names used by demo-k8s.sh
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        info "Loading .env for K8s specific variables..."
        set +u
        TEMP_K8S_NAMESPACE_RESET="${K8S_NAMESPACE_RESET}"
        TEMP_HELM_RELEASE_NAME_RESET="${HELM_RELEASE_NAME_RESET}"
        # shellcheck source=.env
        source "${SCRIPT_DIR}/.env"
        K8S_NAMESPACE_RESET="${K8S_NAMESPACE:-${TEMP_K8S_NAMESPACE_RESET}}"
        HELM_RELEASE_NAME_RESET="${HELM_RELEASE_NAME:-${TEMP_HELM_RELEASE_NAME_RESET}}"
        set -u
    fi
    info "Targeting Helm release '${HELM_RELEASE_NAME_RESET}' in namespace '${K8S_NAMESPACE_RESET}' for cleanup."

    if ! kubectl cluster-info &> /dev/null; then
        warn "Cannot connect to Kubernetes cluster. Skipping Kubernetes reset."
        return
    fi

    info "Uninstalling Helm release '${HELM_RELEASE_NAME_RESET}' from namespace '${K8S_NAMESPACE_RESET}'..."
    if helm uninstall "${HELM_RELEASE_NAME_RESET}" --namespace "${K8S_NAMESPACE_RESET}" &> /dev/null; then
        info "Helm release '${HELM_RELEASE_NAME_RESET}' uninstalled successfully."
    else
        warn "Helm release '${HELM_RELEASE_NAME_RESET}' not found or already uninstalled in namespace '${K8S_NAMESPACE_RESET}'."
    fi

    # Helm 3 should delete PVCs by default. However, we can double check.
    # Assuming PVCs are labeled by Helm: app.kubernetes.io/instance=${HELM_RELEASE_NAME_RESET}
    info "Checking for PVCs associated with release '${HELM_RELEASE_NAME_RESET}' in namespace '${K8S_NAMESPACE_RESET}'..."
    PVCS=$(kubectl get pvc -n "${K8S_NAMESPACE_RESET}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME_RESET}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$PVCS" ]; then
        if confirm "Delete PVCs (${PVCS}) associated with release '${HELM_RELEASE_NAME_RESET}' in namespace '${K8S_NAMESPACE_RESET}'?"; then
            info "Deleting PVCs: ${PVCS}"
            kubectl delete pvc -n "${K8S_NAMESPACE_RESET}" ${PVCS} --wait=true || warn "Failed to delete one or more PVCs. They might be in use or have finalizers."
        else
            info "Skipping PVC deletion."
        fi
    else
        info "No PVCs found with label app.kubernetes.io/instance=${HELM_RELEASE_NAME_RESET}."
    fi

    # Namespace deletion (only if it's a demo-specific one and user confirms)
    if [[ "${K8S_NAMESPACE_RESET}" == "jenkins-demo" || "${K8S_NAMESPACE_RESET}" == *"-demo" ]]; then
        if kubectl get namespace "${K8S_NAMESPACE_RESET}" &> /dev/null; then
            if confirm "Delete namespace '${K8S_NAMESPACE_RESET}'?"; then
                info "Deleting namespace '${K8S_NAMESPACE_RESET}'..."
                kubectl delete namespace "${K8S_NAMESPACE_RESET}" --wait=true || warn "Failed to delete namespace '${K8S_NAMESPACE_RESET}'. It might be stuck in Terminating state."
                info "Namespace '${K8S_NAMESPACE_RESET}' deletion initiated."
            else
                info "Skipping namespace '${K8S_NAMESPACE_RESET}' deletion."
            fi
        else
            info "Namespace '${K8S_NAMESPACE_RESET}' not found, skipping deletion."
        fi
    else
        warn "Namespace '${K8S_NAMESPACE_RESET}' does not look like a demo-specific namespace. Skipping automatic deletion."
    fi

    info "--- Kubernetes Demo Reset Complete ---"
}


# --- Main Execution ---
main_reset() {
    info "========= Starting Demo Reset Script ========="

    if confirm "Do you want to reset the Docker demo environment?"; then
        reset_docker_demo
    else
        info "Skipping Docker demo reset."
    fi

    echo # Add a blank line for readability

    if confirm "Do you want to reset the Kubernetes demo environment?"; then
        reset_kubernetes_demo
    else
        info "Skipping Kubernetes demo reset."
    fi

    info "========= Demo Reset Script Finished ========="
}

# Run main reset function
main_reset
