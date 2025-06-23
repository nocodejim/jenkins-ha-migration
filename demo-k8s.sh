#!/bin/bash

# Strict mode
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Configuration ---
# These can be overridden by environment variables or a .env file (though .env loading is simplified here)
K8S_NAMESPACE="${K8S_NAMESPACE:-jenkins-demo}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-jenkins-demo}"
JENKINS_ADMIN_USER_K8S="${JENKINS_ADMIN_USER_K8S:-admin}"
JENKINS_ADMIN_PASSWORD_K8S="${JENKINS_ADMIN_PASSWORD_K8S:-ChangeMeK8s123!}" # Different default for K8s demo
JENKINS_INGRESS_HOST_K8S="${JENKINS_INGRESS_HOST_K8S:-jenkins-demo.local}" # Example, user needs to manage DNS/hosts

HELM_CHART_PATH="kubernetes/helm"
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

check_prerequisites_k8s() {
    info "Checking Kubernetes prerequisites..."
    command -v kubectl >/dev/null 2>&1 || { error "kubectl is not installed. Please install kubectl and configure access to your Kubernetes cluster."; exit 1; }
    info "kubectl found: $(kubectl version --client --short)"
    command -v helm >/dev/null 2>&1 || { error "Helm is not installed. Please install Helm."; exit 1; }
    info "Helm found: $(helm version --short)"

    info "Checking Kubernetes cluster connectivity..."
    if kubectl cluster-info &> /dev/null; then
        info "Successfully connected to Kubernetes cluster: $(kubectl config current-context)"
    else
        error "Failed to connect to Kubernetes cluster. Check your kubectl configuration."
        exit 1
    fi
    info "Kubernetes prerequisites met."
}

# Simplified .env loading for K8s script - focused on K8S prefixed vars if present
load_env_k8s() {
    info "Loading K8s environment configuration..."
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        info "Found .env file. Sourcing relevant K8s variables."
        set +u
        # Source the .env file and let existing script variables take precedence if not overridden by .env
        # This is a simple way; a more robust way would parse specific vars.
        TEMP_K8S_NAMESPACE="${K8S_NAMESPACE}"
        TEMP_HELM_RELEASE_NAME="${HELM_RELEASE_NAME}"
        TEMP_JENKINS_ADMIN_USER_K8S="${JENKINS_ADMIN_USER_K8S}"
        TEMP_JENKINS_ADMIN_PASSWORD_K8S="${JENKINS_ADMIN_PASSWORD_K8S}"
        TEMP_JENKINS_INGRESS_HOST_K8S="${JENKINS_INGRESS_HOST_K8S}"

        # shellcheck source=.env
        source "${SCRIPT_DIR}/.env"

        K8S_NAMESPACE="${K8S_NAMESPACE:-${TEMP_K8S_NAMESPACE}}"
        HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-${TEMP_HELM_RELEASE_NAME}}"
        JENKINS_ADMIN_USER_K8S="${JENKINS_ADMIN_USER_K8S:-${TEMP_JENKINS_ADMIN_USER_K8S}}"
        JENKINS_ADMIN_PASSWORD_K8S="${JENKINS_ADMIN_PASSWORD_K8S:-${TEMP_JENKINS_ADMIN_PASSWORD_K8S}}"
        JENKINS_INGRESS_HOST_K8S="${JENKINS_INGRESS_HOST_K8S:-${TEMP_JENKINS_INGRESS_HOST_K8S}}"
        set -u
    else
        warn "No .env file found. Using default K8s settings."
    fi
    info "Using Namespace: ${K8S_NAMESPACE}, Helm Release: ${HELM_RELEASE_NAME}"
    warn "Jenkins Admin User: ${JENKINS_ADMIN_USER_K8S}"
    # JENKINS_ADMIN_PASSWORD_K8S is sensitive, not echoing.
}

cleanup_k8s_resources() {
    info "Cleaning up existing Kubernetes resources for release '${HELM_RELEASE_NAME}' in namespace '${K8S_NAMESPACE}'..."

    info "Attempting to uninstall Helm release '${HELM_RELEASE_NAME}' from namespace '${K8S_NAMESPACE}'..."
    helm uninstall "${HELM_RELEASE_NAME}" --namespace "${K8S_NAMESPACE}" 2>/dev/null || \
        warn "Helm release '${HELM_RELEASE_NAME}' not found or already uninstalled in namespace '${K8S_NAMESPACE}'."

    # Helm 3 uninstall should remove PVCs if they were created by the chart and not annotated with "helm.sh/resource-policy: keep"
    # However, let's double-check for PVCs related to the release.
    # This requires knowing the labels used by the Helm chart for its PVCs.
    # Assuming the chart labels PVCs with app.kubernetes.io/instance=${HELM_RELEASE_NAME}
    info "Checking for any remaining PVCs associated with the release..."
    PVC_COUNT=$(kubectl get pvc -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" -o jsonpath='{.items}' | jq 'length' 2>/dev/null || echo 0)
    if [ "${PVC_COUNT}" -gt 0 ]; then
        warn "Found ${PVC_COUNT} PVC(s) potentially related to '${HELM_RELEASE_NAME}'. These might need manual review if not deleted by Helm."
        # Example: kubectl delete pvc -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}"
        # For a demo, it's safer to inform than to auto-delete unknown PVCs unless sure about the labels.
        # The helm chart `values.yaml` has `persistence: enabled: true`. Default Helm behavior is to delete PVCs on uninstall.
    else
        info "No lingering PVCs found with common Helm release labels."
    fi

    info "Checking if namespace '${K8S_NAMESPACE}' should be deleted..."
    # Only delete namespace if it was likely created by this script (e.g. specific demo name)
    # and is not a default/system namespace.
    if [[ "${K8S_NAMESPACE}" == "jenkins-demo" || "${K8S_NAMESPACE}" == *"-demo" ]]; then
        if kubectl get namespace "${K8S_NAMESPACE}" &> /dev/null; then
            read -p "Namespace '${K8S_NAMESPACE}' exists. Delete it? (y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                info "Deleting namespace '${K8S_NAMESPACE}'..."
                kubectl delete namespace "${K8S_NAMESPACE}" --wait=true || error "Failed to delete namespace '${K8S_NAMESPACE}'. It might take time or have finalizers."
                info "Namespace '${K8S_NAMESPACE}' deletion initiated."
            else
                info "Skipping namespace deletion."
            fi
        else
            info "Namespace '${K8S_NAMESPACE}' does not exist or already deleted."
        fi
    else
        warn "Namespace '${K8S_NAMESPACE}' is not a typical demo namespace. Skipping automatic deletion."
    fi

    info "Kubernetes cleanup for '${HELM_RELEASE_NAME}' complete."
}

# --- Main K8s Deployment Functions ---

deploy_jenkins_k8s() {
    info "Deploying Jenkins HA to Kubernetes via Helm..."

    info "Checking if namespace '${K8S_NAMESPACE}' exists..."
    if ! kubectl get namespace "${K8S_NAMESPACE}" &> /dev/null; then
        info "Namespace '${K8S_NAMESPACE}' does not exist. Creating it..."
        kubectl create namespace "${K8S_NAMESPACE}" || { error "Failed to create namespace '${K8S_NAMESPACE}'."; exit 1; }
        info "Namespace '${K8S_NAMESPACE}' created."
    else
        info "Namespace '${K8S_NAMESPACE}' already exists."
    fi

    info "Deploying Helm chart '${HELM_CHART_PATH}' with release name '${HELM_RELEASE_NAME}' into namespace '${K8S_NAMESPACE}'..."

    # Overrides for the Helm chart values
    # Refer to kubernetes/helm/values.yaml for available options
    # Forcing replicaCount to 1 for quicker demo startup, can be 2 for HA demo
    local replica_count_demo=1
    info "Using replicaCount=${replica_count_demo} for faster demo startup. For HA, set to 2 or more."

    helm upgrade --install "${HELM_RELEASE_NAME}" "${HELM_CHART_PATH}" \
        --namespace "${K8S_NAMESPACE}" \
        --set namespace="${K8S_NAMESPACE}" \
        --set replicaCount="${replica_count_demo}" \
        --set jenkins.adminUser="${JENKINS_ADMIN_USER_K8S}" \
        --set jenkins.adminPassword="${JENKINS_ADMIN_PASSWORD_K8S}" \
        --set ingress.enabled=true \
        --set ingress.host="${JENKINS_INGRESS_HOST_K8S}" \
        --set persistence.enabled=true \
        --set persistence.storageClass="" \ # Use default StorageClass or specify one, e.g., from .env
        --set service.type=ClusterIP \ # Default, rely on Ingress
        --wait --timeout 10m # Wait for Helm deployment to complete (pods might still be starting)

    if [ $? -eq 0 ]; then
        info "Helm deployment of '${HELM_RELEASE_NAME}' initiated successfully."
    else
        error "Helm deployment failed. Check Helm output for details."
        # Try to get logs from pods if any started
        kubectl logs --tail=50 -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" || true
        exit 1
    fi
}

_get_jenkins_pod_names_k8s() {
    kubectl get pods -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME},app.kubernetes.io/name=jenkins-ha" -o jsonpath='{.items[*].metadata.name}'
}

wait_for_jenkins_k8s() {
    info "Waiting for Jenkins pods in release '${HELM_RELEASE_NAME}' to be ready..."
    local max_attempts=60 # Approx 10 minutes (60 * 10s)
    local attempt=0

    # Wait for StatefulSet to report readiness for all replicas
    # The chart creates a statefulset named typically ${HELM_RELEASE_NAME}-jenkins-ha if nameOverride is not used
    # Or just ${HELM_RELEASE_NAME} if fullnameOverride is used. Let's use labels.
    # Assuming the Helm chart uses standard labels like app.kubernetes.io/instance and app.kubernetes.io/name

    info "Waiting for StatefulSet/Deployment update to complete for Jenkins..."
    # The chart uses a StatefulSet. The name is derived.
    # Let's assume the statefulset is named like the release or has standard labels.
    # Common pattern: {{ include "jenkins.fullname" . }}
    # From values.yaml, fullnameOverride is empty, nameOverride is empty.
    # So, the statefulset name is likely just ${HELM_RELEASE_NAME} or ${HELM_RELEASE_NAME}-jenkins-ha
    # The template statefulset.yaml uses `name: {{ include "jenkins.fullname" . }}`
    # _helpers.tpl defines `jenkins.fullname`: `{{- .Release.Name | trunc 63 | trimSuffix "-" -}}` if no overrides.
    # So statefulset name should be ${HELM_RELEASE_NAME}.
    local statefulset_name="${HELM_RELEASE_NAME}" # Based on default chart naming

    # Check if StatefulSet exists before waiting
    if ! kubectl get statefulset "${statefulset_name}" -n "${K8S_NAMESPACE}" > /dev/null 2>&1; then
        # Try another common pattern if the above is not found (e.g. if chart has a suffix)
        statefulset_name="${HELM_RELEASE_NAME}-jenkins-ha"
        if ! kubectl get statefulset "${statefulset_name}" -n "${K8S_NAMESPACE}" > /dev/null 2>&1; then
            error "Could not determine Jenkins StatefulSet name. Looked for '${HELM_RELEASE_NAME}' and '${HELM_RELEASE_NAME}-jenkins-ha'."
            error "Skipping wait for StatefulSet readiness. Pod checks will follow."
        fi
    fi

    if kubectl get statefulset "${statefulset_name}" -n "${K8S_NAMESPACE}" > /dev/null 2>&1; then
        info "Waiting for StatefulSet '${statefulset_name}' to be ready..."
        if ! kubectl rollout status statefulset/"${statefulset_name}" -n "${K8S_NAMESPACE}" --timeout=10m; then
            error "Jenkins StatefulSet '${statefulset_name}' did not become ready in time."
            kubectl describe statefulset "${statefulset_name}" -n "${K8S_NAMESPACE}"
            _get_jenkins_pod_names_k8s | xargs -I{} kubectl logs --tail=50 {} -n "${K8S_NAMESPACE}" --all-containers
            exit 1
        fi
        info "Jenkins StatefulSet '${statefulset_name}' is ready."
    fi

    info "Performing additional readiness checks on individual Jenkins pods..."
    # Even if rollout status is ok, ensure pods are truly 'Ready' (all containers) and responding
    POD_NAMES=$(_get_jenkins_pod_names_k8s)
    if [ -z "$POD_NAMES" ]; then
        error "No Jenkins pods found for release '${HELM_RELEASE_NAME}'. Deployment likely failed."
        exit 1
    fi

    for POD_NAME in $POD_NAMES; do
        info "Waiting for pod ${POD_NAME} to be fully ready..."
        if ! kubectl wait --for=condition=Ready pod/"${POD_NAME}" -n "${K8S_NAMESPACE}" --timeout=5m; then
            error "Pod ${POD_NAME} did not become Ready."
            kubectl describe pod "${POD_NAME}" -n "${K8S_NAMESPACE}"
            kubectl logs --tail=50 "${POD_NAME}" -n "${K8S_NAMESPACE}" --all-containers
            exit 1
        fi
        info "Pod ${POD_NAME} is Ready."
    done

    info "All Jenkins pods are ready."
}

# Variable to store determined Jenkins URL
JENKINS_ACCESS_URL_K8S=""

get_k8s_access_urls() {
    info "Determining Jenkins access URL..."
    # Check Ingress first
    local ingress_name="${HELM_RELEASE_NAME}" # Assuming Ingress name matches release name (common pattern)

    if kubectl get ingress "${ingress_name}" -n "${K8S_NAMESPACE}" &> /dev/null; then
        # Try to get host from ingress spec. JENKINS_INGRESS_HOST_K8S is what we set.
        JENKINS_ACCESS_URL_K8S="http://${JENKINS_INGRESS_HOST_K8S}" # Default to http, user might have https
        # Check if TLS is configured on Ingress to suggest https
        local tls_hosts
        tls_hosts=$(kubectl get ingress "${ingress_name}" -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.tls[*].hosts[*]}' 2>/dev/null || true)
        if [[ -n "$tls_hosts" && "$tls_hosts" == *"${JENKINS_INGRESS_HOST_K8S}"* ]]; then
            JENKINS_ACCESS_URL_K8S="https://${JENKINS_INGRESS_HOST_K8S}"
            info "Jenkins Ingress found with TLS: ${JENKINS_ACCESS_URL_K8S}"
        else
            info "Jenkins Ingress found (HTTP or TLS not matching host): ${JENKINS_ACCESS_URL_K8S}"
        fi
        info "Ensure '${JENKINS_INGRESS_HOST_K8S}' resolves to your Ingress controller's IP."
        info "You might need to update your /etc/hosts file or DNS records."
        echo "Example /etc/hosts entry: <INGRESS_CONTROLLER_IP> ${JENKINS_INGRESS_HOST_K8S}"
        return 0
    else
        warn "Ingress '${ingress_name}' not found. Trying to find Ingress by labels..."
        # Fallback: try finding ingress by release label (more robust)
        local ingress_found_by_label
        ingress_found_by_label=$(kubectl get ingress -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
        if [ -n "$ingress_found_by_label" ]; then
            JENKINS_INGRESS_HOST_K8S="$ingress_found_by_label" # Update if found differently
            JENKINS_ACCESS_URL_K8S="http://${JENKINS_INGRESS_HOST_K8S}"
            local tls_hosts_label
            tls_hosts_label=$(kubectl get ingress -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" -o jsonpath='{.items[0].spec.tls[*].hosts[*]}' 2>/dev/null || true)
             if [[ -n "$tls_hosts_label" && "$tls_hosts_label" == *"${JENKINS_INGRESS_HOST_K8S}"* ]]; then
                JENKINS_ACCESS_URL_K8S="https://${JENKINS_INGRESS_HOST_K8S}"
                info "Jenkins Ingress (found by label) with TLS: ${JENKINS_ACCESS_URL_K8S}"
            else
                info "Jenkins Ingress (found by label, HTTP or TLS not matching host): ${JENKINS_ACCESS_URL_K8S}"
            fi
            info "Ensure '${JENKINS_INGRESS_HOST_K8S}' resolves to your Ingress controller's IP."
            return 0
        fi
        warn "No Ingress found for Jenkins. Checking for LoadBalancer or NodePort service..."
    fi

    # Check for LoadBalancer Service
    local service_name="${HELM_RELEASE_NAME}" # Assuming Service name also matches release name
    # The service name is also likely {{ include "jenkins.fullname" . }}
    local lb_ip
    lb_ip=$(kubectl get service "${service_name}" -n "${K8S_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
            kubectl get service "${service_name}" -n "${K8S_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$lb_ip" ]; then
        local service_port=$(kubectl get service "${service_name}" -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')
        JENKINS_ACCESS_URL_K8S="http://${lb_ip}:${service_port}"
        info "Jenkins accessible via LoadBalancer: ${JENKINS_ACCESS_URL_K8S}"
        return 0
    fi
    warn "No LoadBalancer service found for Jenkins."

    # Check for NodePort Service (less ideal for external access but good for local testing)
    local node_port
    node_port=$(kubectl get service "${service_name}" -n "${K8S_NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || true)
    if [ -n "$node_port" ]; then
        local any_node_ip # This is tricky, need a node IP. User must find one.
        any_node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<ANY_NODE_IP>")
        JENKINS_ACCESS_URL_K8S="http://${any_node_ip}:${node_port}"
        info "Jenkins accessible via NodePort: ${JENKINS_ACCESS_URL_K8S}"
        warn "Replace <ANY_NODE_IP> with an actual IP of one of your Kubernetes nodes."
        return 0
    fi
    warn "No NodePort service found for Jenkins."

    error "Could not determine Jenkins access URL. Manual check required."
    info "You might need to use 'kubectl port-forward svc/${service_name} <local_port>:8080 -n ${K8S_NAMESPACE}' and access via http://localhost:<local_port>"
    JENKINS_ACCESS_URL_K8S="" # Unset if not found
    return 1
}

get_jenkins_crumb_k8s() {
    if [ -z "${JENKINS_ACCESS_URL_K8S}" ]; then
        error "Jenkins access URL is not set. Cannot fetch crumb."
        return 1
    fi
    info "Fetching Jenkins CSRF crumb from ${JENKINS_ACCESS_URL_K8S}..."
    # Use -k for self-signed certs if Ingress uses them or if local resolution issues
    CRUMB=$(curl -k -s -u "${JENKINS_ADMIN_USER_K8S}:${JENKINS_ADMIN_PASSWORD_K8S}" \
        "${JENKINS_ACCESS_URL_K8S}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")

    if [ -z "$CRUMB" ]; then
        error "Failed to fetch Jenkins CSRF crumb from ${JENKINS_ACCESS_URL_K8S}."
        # For debugging, show verbose output if curl fails
        verbose_output=$(curl -k -v -u "${JENKINS_ADMIN_USER_K8S}:${JENKINS_ADMIN_PASSWORD_K8S}" "${JENKINS_ACCESS_URL_K8S}/crumbIssuer/api/xml" 2>&1)
        error "Debug curl output for crumb: ${verbose_output}"
        return 1
    else
        info "Jenkins CSRF crumb fetched successfully from ${JENKINS_ACCESS_URL_K8S}."
        echo "$CRUMB"
        return 0
    fi
}

create_sample_job_k8s() {
    if [ -z "${JENKINS_ACCESS_URL_K8S}" ]; then
        error "Jenkins access URL is not set. Cannot create sample job."
        return 1
    fi

    local job_name="K8s-Sample-Demo-Pipeline"
    local job_config_xml

    info "Attempting to create sample Jenkins job '${job_name}' on ${JENKINS_ACCESS_URL_K8S}..."

    JENKINS_CRUMB_K8S=$(get_jenkins_crumb_k8s)
    if [ $? -ne 0 ] || [ -z "${JENKINS_CRUMB_K8S}" ]; then
        error "Cannot create sample job due to missing CSRF crumb."
        return 1
    fi

    job_config_xml=$(cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@1385.vb_58b_86ea_fff1">
  <actions/>
  <description>A sample pipeline job created by the K8s demo script.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps@3837.v3de5c9240516">
    <script>
pipeline {
    agent any // For K8s, 'agent { kubernetes { ... } }' would be more typical if chart sets up pod templates

    stages {
        stage('Hello K8s') {
            steps {
                echo 'Hello from Kubernetes Demo Pipeline!'
                sh 'date'
                sh 'echo "Running inside: $(hostname)"'
            }
        }
        stage('Success') {
            steps {
                echo 'K8s Pipeline completed successfully.'
            }
        }
    }
}
    </script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF
)
    JOB_EXISTS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${JENKINS_ADMIN_USER_K8S}:${JENKINS_ADMIN_PASSWORD_K8S}" \
        "${JENKINS_ACCESS_URL_K8S}/job/${job_name}/config.xml")

    if [ "$JOB_EXISTS_CODE" == "200" ]; then
        info "Job '${job_name}' already exists. Updating it."
        RESPONSE_CODE=$(curl -k -s -o /dev/stderr -w "%{http_code}" -X POST -u "${JENKINS_ADMIN_USER_K8S}:${JENKINS_ADMIN_PASSWORD_K8S}" \
            -H "${JENKINS_CRUMB_K8S}" \
            -H "Content-Type: application/xml" \
            --data-binary "${job_config_xml}" \
            "${JENKINS_ACCESS_URL_K8S}/job/${job_name}/config.xml")
    else
        info "Job '${job_name}' does not exist. Creating it."
        RESPONSE_CODE=$(curl -k -s -o /dev/stderr -w "%{http_code}" -X POST -u "${JENKINS_ADMIN_USER_K8S}:${JENKINS_ADMIN_PASSWORD_K8S}" \
            -H "${JENKINS_CRUMB_K8S}" \
            -H "Content-Type: application/xml" \
            --data-binary "${job_config_xml}" \
            "${JENKINS_ACCESS_URL_K8S}/createItem?name=${job_name}")
    fi

    if [[ "$RESPONSE_CODE" == "200" || "$RESPONSE_CODE" == "302" ]]; then # 302 can happen on create
        info "Sample Jenkins job '${job_name}' created/updated successfully (HTTP ${RESPONSE_CODE})."
    else
        error "Failed to create/update sample Jenkins job '${job_name}' (HTTP ${RESPONSE_CODE}). Check Jenkins logs or output above."
        return 1
    fi
    info "To trigger the job: ${JENKINS_ACCESS_URL_K8S}/job/${job_name}/build?delay=0sec"
}

validate_deployment_k8s() {
    info "Validating Kubernetes deployment..."
    local all_ok=true

    if [ -z "${JENKINS_ACCESS_URL_K8S}" ]; then
        error "Jenkins Access URL not determined. Skipping validation of Jenkins endpoint."
        all_ok=false
    elif curl -k -s --fail "${JENKINS_ACCESS_URL_K8S}/login" > /dev/null; then
        info "Jenkins endpoint (${JENKINS_ACCESS_URL_K8S}/login) is accessible."
    else
        error "Jenkins endpoint (${JENKINS_ACCESS_URL_K8S}/login) is NOT accessible."
        all_ok=false
    fi

    warn "Monitoring validation: The Helm chart deploys a ServiceMonitor for Prometheus."
    warn "For this to function, a Prometheus Operator (e.g., from kube-prometheus-stack) must be running in your cluster"
    warn "and configured to discover ServiceMonitors in the '${K8S_NAMESPACE}' namespace (or the namespace specified in values.yaml for monitoring.serviceMonitor.namespace)."
    warn "The default ServiceMonitor namespace in values.yaml is 'monitoring'."
    # Check if ServiceMonitor was created
    if kubectl get servicemonitor -n "${K8S_NAMESPACE}" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" &> /dev/null; then
        info "ServiceMonitor for Jenkins found in namespace '${K8S_NAMESPACE}'."
    elif kubectl get servicemonitor -n "monitoring" -l "app.kubernetes.io/instance=${HELM_RELEASE_NAME}" &> /dev/null; then
         info "ServiceMonitor for Jenkins found in namespace 'monitoring'."
    else
        warn "ServiceMonitor for Jenkins not found in '${K8S_NAMESPACE}' or 'monitoring' namespace. Prometheus integration might not be working."
    fi

    if $all_ok; then
        info "Basic K8s validation checks passed."
    else
        error "Some K8s validation checks failed. Please review the logs."
    fi
}

print_access_info_k8s() {
    info "--- Kubernetes Access Information ---"
    if [ -n "${JENKINS_ACCESS_URL_K8S}" ]; then
        echo -e "${YELLOW}Jenkins URL:${NC} ${JENKINS_ACCESS_URL_K8S}/"
        echo -e "${YELLOW}Sample Jenkins Job:${NC} ${JENKINS_ACCESS_URL_K8S}/job/K8s-Sample-Demo-Pipeline/"
    else
        echo -e "${RED}Jenkins URL could not be automatically determined.${NC}"
        echo -e "Try 'kubectl get svc,ing -n ${K8S_NAMESPACE}' or use port-forwarding."
        echo -e "Example: kubectl port-forward svc/${HELM_RELEASE_NAME} 8080:8080 -n ${K8S_NAMESPACE}"
        echo -e "Then access at http://localhost:8080"
    fi
    echo -e "${YELLOW}Jenkins Admin User:${NC} ${JENKINS_ADMIN_USER_K8S}"
    echo -e "${YELLOW}Jenkins Admin Password:${NC} ${JENKINS_ADMIN_PASSWORD_K8S}"
    echo -e ""
    echo -e "${YELLOW}To access Jenkins pods:${NC}"
    echo -e "  kubectl get pods -n ${K8S_NAMESPACE} -l app.kubernetes.io/instance=${HELM_RELEASE_NAME}"
    echo -e "${YELLOW}To view Jenkins logs (example for first pod):${NC}"
    local first_pod=$(_get_jenkins_pod_names_k8s | awk '{print $1}')
    if [ -n "$first_pod" ]; then
        echo -e "  kubectl logs -f ${first_pod} -n ${K8S_NAMESPACE}"
    fi
    echo -e ""
    echo -e "${YELLOW}Helm Release Name:${NC} ${HELM_RELEASE_NAME}"
    echo -e "${YELLOW}Namespace:${NC} ${K8S_NAMESPACE}"
    echo -e ""
    if [[ "${JENKINS_ACCESS_URL_K8S}" == *"${JENKINS_INGRESS_HOST_K8S}"* ]]; then
        warn "If using Ingress (${JENKINS_INGRESS_HOST_K8S}), ensure it resolves to your Ingress controller IP."
        warn "Update /etc/hosts or DNS: <INGRESS_CONTROLLER_IP> ${JENKINS_INGRESS_HOST_K8S}"
    fi
    info "--- End of Kubernetes Access Information ---"
}


# --- Main K8s Execution ---
main_k8s() {
    trap 'echo "Exiting K8s demo script prematurely. Resources might need manual cleanup for release ${HELM_RELEASE_NAME} in namespace ${K8S_NAMESPACE}."' ERR EXIT

    info "Starting Kubernetes Demo Deployment Script..."

    check_prerequisites_k8s
    load_env_k8s

    # Ask before cleaning up, as K8s resources can be more persistent/shared
    read -p "Do you want to clean up any existing '${HELM_RELEASE_NAME}' resources in namespace '${K8S_NAMESPACE}' before proceeding? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_k8s_resources
    else
        info "Skipping cleanup of existing resources."
    fi

    deploy_jenkins_k8s
    wait_for_jenkins_k8s

    get_k8s_access_urls # Sets JENKINS_ACCESS_URL_K8S

    if [ -n "${JENKINS_ACCESS_URL_K8S}" ]; then
        # Wait a few more seconds for Jenkins to be fully responsive through Ingress/LB
        info "Waiting a bit longer for Jenkins to be fully available via ${JENKINS_ACCESS_URL_K8S}..."
        sleep 15
        create_sample_job_k8s
    else
        warn "Skipping sample job creation as Jenkins URL could not be determined."
    fi

    validate_deployment_k8s
    print_access_info_k8s

    info "Kubernetes Demo Deployment Completed!"
    info "Access Jenkins at: ${JENKINS_ACCESS_URL_K8S:-Manually determined URL}"
    info "To clean up, run this script again and choose 'y' for cleanup, or run demo-reset.sh."

    # Remove trap for normal exit
    trap - ERR EXIT
}

# Run main K8s function
main_k8s
