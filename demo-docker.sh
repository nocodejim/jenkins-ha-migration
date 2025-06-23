#!/bin/bash

# Strict mode
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values (can be overridden by .env file or environment variables)
JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-ChangeMe123!}"
JENKINS_URL_BASE_DOCKER="${JENKINS_URL_BASE_DOCKER:-https://localhost}" # Assuming Nginx listens on localhost for Docker

COMPOSE_FILE_JENKINS="docker-compose/docker-compose.yml"
COMPOSE_FILE_MONITORING_ORIGINAL="docker-compose/monitoring/docker-compose.yml"
PROMETHEUS_CONFIG_ORIGINAL="docker-compose/monitoring/prometheus/prometheus.yml"

# Temporary files for modified configurations
TMP_COMPOSE_FILE_MONITORING="docker-compose/monitoring/docker-compose.monitoring.jenkins-scrape.yml"
TMP_PROMETHEUS_CONFIG="docker-compose/monitoring/prometheus/prometheus.jenkins-scrape.yml"

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

check_prerequisites() {
    info "Checking prerequisites..."
    command -v docker >/dev/null 2>&1 || { error "Docker is not installed. Please install Docker and try again."; exit 1; }
    info "Docker found: $(docker --version)"
    command -v docker-compose >/dev/null 2>&1 || { error "Docker Compose is not installed. Please install Docker Compose and try again."; exit 1; }
    info "Docker Compose found: $(docker-compose --version)"
    info "Prerequisites met."
}

load_env() {
    info "Loading environment configuration..."
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        info "Found .env file. Sourcing it."
        # Temporarily disable unbound variable errors for sourcing
        set +u
        # shellcheck source=.env
        source "${SCRIPT_DIR}/.env"
        set -u
        # Re-assign defaults if variables are empty after sourcing .env
        JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
        JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-ChangeMe123!}"
        JENKINS_URL_BASE_DOCKER="${JENKINS_URL_BASE_DOCKER:-https://localhost}"
    else
        warn "No .env file found. Using default credentials and settings."
        warn "Jenkins Admin User: ${JENKINS_ADMIN_USER}"
        warn "Jenkins Admin Password: ${JENKINS_ADMIN_PASSWORD} (Consider changing this!)"
    fi
    # Export them so docker-compose can pick them up if they are used in compose files directly
    export JENKINS_ADMIN_USER
    export JENKINS_ADMIN_PASSWORD
    # JENKINS_HOME_PATH is used by docker-compose/docker-compose.yml
    export JENKINS_HOME_PATH="${SCRIPT_DIR}/docker-compose/jenkins_home"
}

cleanup_docker_resources() {
    info "Cleaning up existing Docker resources (if any)..."

    info "Stopping and removing Jenkins services defined in ${COMPOSE_FILE_JENKINS}..."
    docker-compose -f "${COMPOSE_FILE_JENKINS}" down -v --remove-orphans 2>/dev/null || true

    info "Stopping and removing monitoring services defined in ${COMPOSE_FILE_MONITORING_ORIGINAL}..."
    docker-compose -f "${COMPOSE_FILE_MONITORING_ORIGINAL}" down -v --remove-orphans 2>/dev/null || true

    if [ -f "${TMP_COMPOSE_FILE_MONITORING}" ]; then
        info "Stopping and removing monitoring services defined in ${TMP_COMPOSE_FILE_MONITORING}..."
        docker-compose -f "${TMP_COMPOSE_FILE_MONITORING}" down -v --remove-orphans 2>/dev/null || true
    fi

    # Clean up temporary files
    rm -f "${TMP_COMPOSE_FILE_MONITORING}" "${TMP_PROMETHEUS_CONFIG}"

    # Optional: More aggressive cleanup (be careful with this)
    # read -p "Do you want to perform a more aggressive Docker system prune (removes unused data)? (y/N): " -r
    # if [[ $REPLY =~ ^[Yy]$ ]]; then
    #     info "Pruning Docker system..."
    #     docker system prune -af --volumes || true
    # fi
    info "Docker cleanup complete."
}

run_setup_script() {
    info "Running setup.sh to prepare directories and certificates..."
    if [ -f "${SCRIPT_DIR}/setup.sh" ]; then
        # setup.sh uses sudo, so we might need to inform the user or handle it.
        # For now, assume the user can run sudo or has run it.
        if bash "${SCRIPT_DIR}/setup.sh"; then
            info "setup.sh completed successfully."
        else
            error "setup.sh failed. Please check its output."
            # Decide if this is a fatal error for the demo script
            # exit 1
            warn "Continuing despite setup.sh issues. SSL certs for Nginx might be missing."
        fi
    else
        warn "setup.sh not found. Skipping directory and certificate setup. This might cause issues."
    fi
}

# --- Main Deployment Functions ---

deploy_jenkins_stack() {
    info "Deploying Jenkins HA stack using ${COMPOSE_FILE_JENKINS}..."
    # Ensure JENKINS_HOME_PATH is set for the compose file
    mkdir -p "${JENKINS_HOME_PATH}"
    # The setup.sh script should handle chown, but good to ensure it exists.

    docker-compose -f "${COMPOSE_FILE_JENKINS}" up -d --remove-orphans
    info "Jenkins HA stack deployment initiated."
}

prepare_monitoring_configs() {
    info "Preparing modified configurations for monitoring stack..."

    # Create temporary Prometheus config to scrape Jenkins
    cat << EOF > "${TMP_PROMETHEUS_CONFIG}"
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'jenkins'
    # Assuming jenkins-1 and jenkins-2 are resolvable on jenkins-net
    # and are exposing metrics at /prometheus as per labels in main docker-compose
    # Docker's embedded DNS server allows resolution of container names on user-defined networks.
    static_configs:
      - targets: ['jenkins-1:8080', 'jenkins-2:8080']
    metrics_path: /prometheus # Path defined in jenkins container labels

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100'] # Assuming node-exporter is the service name in monitoring compose

  - job_name: 'grafana' # Optional: Grafana itself has metrics
    static_configs:
      - targets: ['grafana:3000']

  # Add other services from the original monitoring prometheus.yml if needed
  # For now, focusing on Jenkins, Prometheus, Node Exporter, Grafana
EOF
    info "Created temporary Prometheus config at ${TMP_PROMETHEUS_CONFIG}"

    # Create temporary Docker Compose for monitoring, adding Prometheus to jenkins-net
    # This is a bit verbose. A better way might be using yq or similar if available,
    # or using docker-compose override files. For a bash script, this is explicit.
    if ! command -v yq &> /dev/null && ! command -v python &> /dev/null ; then
        warn "yq or python is not installed. Creating a simplified temporary monitoring compose file."
        warn "This might not perfectly replicate all features of the original monitoring compose if it's complex."
        cat << EOF > "${TMP_COMPOSE_FILE_MONITORING}"
version: '3.7'
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ${PWD}/${TMP_PROMETHEUS_CONFIG}:/etc/prometheus/prometheus.yml # Use absolute path for volume
      - ${PWD}/docker-compose/monitoring/prometheus/alerts:/etc/prometheus/alerts
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - '9090:9090'
    networks: # Add prometheus to jenkins-net
      - jenkins-net
      - default # Keep its own default network for other monitoring components if they don't need jenkins-net

  grafana:
    image: grafana/grafana:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/grafana/dashboards:/var/lib/grafana/dashboards
      # Grafana provisioning for datasources and dashboards
      - ${PWD}/docker-compose/monitoring/grafana/provisioning:/etc/grafana/provisioning
    ports:
      - '3000:3000'
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin} # Default Grafana creds
    networks:
      - default # Grafana doesn't directly need jenkins-net unless it scrapes Jenkins directly (Prometheus does that)
    depends_on:
      - prometheus

  alertmanager:
    image: prom/alertmanager:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports:
      - '9093:9093'
    networks:
      - default

  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - '9100:9100'
    networks:
      - default

networks:
  jenkins-net: # Define jenkins-net as external so Prometheus can join it
    external: true
  default: # Default network for monitoring stack internal communication
    driver: bridge
EOF
    else
      info "Using yq/python to generate temporary monitoring compose file (more robust)."
      # If yq is available, it's better for modifying YAML.
      # For now, the simpler cat-based approach is used for wider compatibility in a demo script.
      # If yq was a prerequisite:
      # yq eval '.services.prometheus.networks += {"jenkins-net": null}' docker-compose/monitoring/docker-compose.yml > ${TMP_COMPOSE_FILE_MONITORING}
      # yq eval '.networks."jenkins-net".external = true' -i ${TMP_COMPOSE_FILE_MONITORING}
      # Fallback to the simpler version if yq is not present
      cp "${COMPOSE_FILE_MONITORING_ORIGINAL}" "${TMP_COMPOSE_FILE_MONITORING}"
      # This is a placeholder for a more robust modification if yq/python were used.
      # The cat EOF method above is more portable for a demo script.
      # For now, we'll stick to the cat EOF method for simplicity and explicitness.
      # Re-using the cat EOF from above for clarity that it's the chosen method for now:
      cat << EOF > "${TMP_COMPOSE_FILE_MONITORING}"
version: '3.7'
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ${PWD}/${TMP_PROMETHEUS_CONFIG}:/etc/prometheus/prometheus.yml
      - ${PWD}/docker-compose/monitoring/prometheus/alerts:/etc/prometheus/alerts
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - '9090:9090'
    networks:
      - jenkins-net
      - default
  grafana:
    image: grafana/grafana:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/grafana/dashboards:/var/lib/grafana/dashboards
      - ${PWD}/docker-compose/monitoring/grafana/provisioning:/etc/grafana/provisioning
    ports:
      - '3000:3000'
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin}
    networks:
      - default
    depends_on:
      - prometheus
  alertmanager:
    image: prom/alertmanager:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports:
      - '9093:9093'
    networks:
      - default
  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - '9100:9100'
    networks:
      - default
networks:
  jenkins-net:
    name: docker-compose_jenkins-net # Match the network name created by the main compose file
    external: true
  default:
    driver: bridge
EOF
    fi
    info "Created temporary monitoring compose file at ${TMP_COMPOSE_FILE_MONITORING}"
}

deploy_monitoring_stack() {
    prepare_monitoring_configs
    info "Deploying monitoring stack using ${TMP_COMPOSE_FILE_MONITORING}..."
    # The jenkins-net is created by the main docker-compose.yml.
    # The monitoring compose file should declare it as external.
    # The name of the network created by `docker-compose -f docker-compose/docker-compose.yml`
    # will be prefixed with the project name (directory name by default, e.g., `docker-compose_jenkins-net`).
    # Need to ensure the external network name matches.
    # The main docker-compose.yml explicitly names the network `jenkins-net`.
    # Let's check the actual network name created by the first compose file.
    # It is defined as `jenkins-net` in the main compose file, so it should be `jenkins-net` if `COMPOSE_PROJECT_NAME` is not set.
    # If `COMPOSE_PROJECT_NAME` (e.g., `jenkins-ha` from .env.example) is used for the Jenkins stack,
    # the network will be `jenkins-ha_jenkins-net`.
    # The `docker-compose.yml` has `networks: jenkins-net: driver: bridge ...`
    # So the network name should be `docker-compose_jenkins-net` if project name is `docker-compose` (dir name).
    # Or `your-project_jenkins-net` if a project name is set.
    # The `x-jenkins-common` uses `networks: - jenkins-net`.
    # The network definition is `jenkins-net: driver: bridge`.
    # So the network name should be `[project_name_jenkins-stack]_jenkins-net`.
    # The .env.example defines `COMPOSE_PROJECT_NAME=jenkins-ha`. So network will be `jenkins-ha_jenkins-net`.
    # The temporary monitoring compose file needs to refer to this exact name.
    # The `docker-compose.yml` defines `networks: jenkins-net: ...`.
    # The actual network name created by Docker Compose will be prefixed with the project name.
    # The project name is determined by `COMPOSE_PROJECT_NAME` env var, or defaults to the directory name
    # of the main compose file (e.g., 'docker-compose' if run from root, or the value of COMPOSE_PROJECT_NAME).
    # The `.env.example` suggests `COMPOSE_PROJECT_NAME=jenkins-ha`.
    # We need to construct this name for the external network definition in the monitoring compose.
    local jenkins_project_name="${COMPOSE_PROJECT_NAME:-$(basename "$(dirname "${COMPOSE_FILE_JENKINS}")")}"
    local actual_jenkins_network_name="${jenkins_project_name}_jenkins-net"

    info "The main Jenkins network is expected to be named: ${actual_jenkins_network_name}"

    # Update the temporary monitoring compose file to use the correct external network name.
    # This is done by replacing a placeholder in the heredoc.
    # For simplicity, the heredoc for TMP_COMPOSE_FILE_MONITORING was updated directly.
    # The heredoc now uses:
    # networks:
    #   jenkins-net:
    #     name: "${actual_jenkins_network_name}" # This will be replaced by the shell
    #     external: true
    #   default:
    #     driver: bridge
    # This requires the cat EOF for TMP_COMPOSE_FILE_MONITORING to be eval'd or to be more dynamic.
    # Let's regenerate the file with the correct network name.

cat << EOF > "${TMP_COMPOSE_FILE_MONITORING}"
version: '3.7'
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ${PWD}/${TMP_PROMETHEUS_CONFIG}:/etc/prometheus/prometheus.yml
      - ${PWD}/docker-compose/monitoring/prometheus/alerts:/etc/prometheus/alerts
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - '9090:9090'
    networks:
      - jenkins-net
      - default
  grafana:
    image: grafana/grafana:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/grafana/dashboards:/var/lib/grafana/dashboards
      - ${PWD}/docker-compose/monitoring/grafana/provisioning:/etc/grafana/provisioning
    ports:
      - '3000:3000'
    environment:
      - GF_SECURITY_ADMIN_USER=\${GRAFANA_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD:-admin}
    networks:
      - default
    depends_on:
      - prometheus
  alertmanager:
    image: prom/alertmanager:latest
    volumes:
      - ${PWD}/docker-compose/monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
    ports:
      - '9093:9093'
    networks:
      - default
  node-exporter:
    image: prom/node-exporter:latest
    ports:
      - '9100:9100'
    networks:
      - default
networks:
  jenkins-net:
    name: "${actual_jenkins_network_name}"
    external: true
  default:
    driver: bridge
EOF
    info "Updated temporary monitoring compose file at ${TMP_COMPOSE_FILE_MONITORING} to use network '${actual_jenkins_network_name}'"

    # Now deploy using the potentially custom project name for monitoring as well, to avoid conflicts.
    # Or, ensure its project name is different from the main Jenkins stack.
    # Using a fixed project name for monitoring is safer here.
    docker-compose -p jenkins-monitoring -f "${TMP_COMPOSE_FILE_MONITORING}" up -d --remove-orphans
    info "Monitoring stack deployment initiated with project name 'jenkins-monitoring'."
}

wait_for_service() {
    local service_name="$1"
    local health_url="$2"
    local compose_file_path="$3"
    local container_name_pattern="$4" # Optional: for more specific container health check
    local max_attempts=30 # Approx 5 minutes (30 * 10s)
    local attempt=0
    local timeout_curl=5 # seconds for curl timeout

    info "Waiting for ${service_name} to be ready at ${health_url}..."

    while [ $attempt -lt $max_attempts ]; do
        # First, check if the container(s) are running and healthy via Docker
        local healthy_containers=0
        local total_containers=0

        # Get all container names for the service from the compose file
        # This is a bit tricky as docker-compose ps -q SERVICE only gives IDs
        # And container names can have project prefix.
        # The main jenkins compose has `container_name` set, so that's easier.
        # For monitoring, they don't.

        if [ -n "$container_name_pattern" ]; then
            # Using a pattern for container names (e.g., jenkins-1, jenkins-2)
            # This is more reliable if container_name is set in docker-compose.yml
             if docker ps --filter "name=${container_name_pattern}" --filter "health=healthy" -q | grep -q .; then
                info "${service_name} container matching '${container_name_pattern}' is healthy."
                healthy_containers=$((healthy_containers + 1))
             elif docker ps --filter "name=${container_name_pattern}" --filter "status=running" -q | grep -q .; then
                 # Container is running but not necessarily healthy (or no healthcheck defined)
                 # For services without healthchecks in compose, we rely on curl
                 : # Do nothing, proceed to curl check
             else
                warn "${service_name} container matching '${container_name_pattern}' is not running or not found."
             fi
             total_containers=1 # Assuming one container matches the specific name for this check
        else
            # Generic check for services where container_name is not fixed or multiple exist
            # This part is less reliable for specific health, relies more on curl
            if docker-compose -f "$compose_file_path" ps -q "$service_name" | xargs -I {} docker inspect {} --format '{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
                info "${service_name} is reported as healthy by Docker."
                healthy_containers=$((healthy_containers + $(docker-compose -f "$compose_file_path" ps -q "$service_name" | wc -l)))
            elif docker-compose -f "$compose_file_path" ps -q "$service_name" | xargs -I {} docker inspect {} --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
                 : # Running, proceed to curl
            fi
            total_containers=$(docker-compose -f "$compose_file_path" ps -q "$service_name" | wc -l)
        fi

        # Then, try to curl the health_url
        # The -k is important for self-signed certs (e.g. Nginx for Jenkins)
        # The --fail makes curl return an error code on HTTP errors (4xx, 5xx)
        if curl -k --silent --fail --max-time ${timeout_curl} "${health_url}" &> /dev/null; then
            info "${service_name} is responding at ${health_url}."
            # If we have a specific container health check and it passed, or if curl passes, we're good.
            if [ -n "$container_name_pattern" ] && [ "$healthy_containers" -gt 0 ]; then
                 info "${service_name} (container ${container_name_pattern}) is fully ready."
                 return 0
            elif [ -z "$container_name_pattern" ]; then # No specific container, curl is enough
                 info "${service_name} is fully ready."
                 return 0
            fi
        fi

        attempt=$((attempt + 1))
        info "Attempt ${attempt}/${max_attempts}: ${service_name} not ready yet. Retrying in 10 seconds..."
        sleep 10
    done

    error "${service_name} did not become ready after ${max_attempts} attempts."
    # Optionally, print logs of failed services
    if [ -n "$container_name_pattern" ]; then
        error "Last logs for ${container_name_pattern}:"
        docker logs --tail 50 "${container_name_pattern}" || true
    else
        error "Last logs for service ${service_name} (from ${compose_file_path}):"
        docker-compose -f "${compose_file_path}" logs --tail 50 "${service_name}" || true
    fi
    return 1
}


wait_for_jenkins_instances() {
    info "Waiting for Jenkins instances to become available..."
    # Jenkins instances are behind Nginx if accessed via JENKINS_URL_BASE_DOCKER
    # but healthchecks in docker-compose.yml target jenkins-1:8080 and jenkins-2:8080 directly
    # The `docker inspect ... Health.Status` is the most reliable for these.

    # Wait for jenkins-1 (using container_name from docker-compose.yml)
    wait_for_service "Jenkins-1" "http://localhost:8080/login" "${COMPOSE_FILE_JENKINS}" "jenkins-1" || exit 1
    # Wait for jenkins-2
    wait_for_service "Jenkins-2" "http://localhost:8081/login" "${COMPOSE_FILE_JENKINS}" "jenkins-2" || exit 1

    # Also check Nginx endpoint as it's the main entry point
    wait_for_service "Jenkins via Nginx" "${JENKINS_URL_BASE_DOCKER}/login" "${COMPOSE_FILE_JENKINS}" "jenkins-lb" || exit 1

    info "All Jenkins instances and Nginx are responsive."
}

wait_for_monitoring_services() {
    info "Waiting for monitoring services..."
    # Prometheus
    wait_for_service "Prometheus" "http://localhost:9090/-/ready" "${TMP_COMPOSE_FILE_MONITORING}" "" || error "Prometheus failed to start, proceeding without it."
    # Grafana
    # Grafana's health check is usually /api/health
    wait_for_service "Grafana" "http://localhost:3000/api/health" "${TMP_COMPOSE_FILE_MONITORING}" "" || error "Grafana failed to start, proceeding without it."
    info "Monitoring services checked."
}

# --- Jenkins Job Creation ---
JENKINS_API_USER="${JENKINS_ADMIN_USER}"
JENKINS_API_TOKEN="${JENKINS_ADMIN_PASSWORD}" # For basic auth with username/password

get_jenkins_crumb() {
    local jenkins_host_port="$1" # e.g., localhost:8080 for direct access, or JENKINS_URL_BASE_DOCKER for via Nginx
    info "Fetching Jenkins CSRF crumb from ${jenkins_host_port}..."
    # Use -k for self-signed certs if accessing via Nginx HTTPS
    # The URL for crumb issuer might vary based on Jenkins version, but this is common
    CRUMB=$(curl -k -s -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" \
        "${jenkins_host_port}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")

    if [ -z "$CRUMB" ]; then
        error "Failed to fetch Jenkins CSRF crumb from ${jenkins_host_port}. Job creation might fail."
        error "Response: $(curl -k -v -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" "${jenkins_host_port}/crumbIssuer/api/xml")"
        return 1
    else
        info "Jenkins CSRF crumb fetched successfully from ${jenkins_host_port}."
        echo "$CRUMB"
        return 0
    fi
}

create_sample_jenkins_job() {
    local job_name="Sample-Demo-Pipeline"
    local job_config_xml
    # Using JENKINS_URL_BASE_DOCKER which goes through Nginx
    local target_jenkins_url="${JENKINS_URL_BASE_DOCKER}"

    info "Attempting to create sample Jenkins job '${job_name}' on ${target_jenkins_url}..."

    JENKINS_CRUMB=$(get_jenkins_crumb "${target_jenkins_url}")
    if [ $? -ne 0 ] || [ -z "${JENKINS_CRUMB}" ]; then
        error "Cannot create sample job due to missing CSRF crumb."
        return 1
    fi

    # Simple Pipeline Job XML
    # This job just prints "Hello from Demo Pipeline" and the current date.
    job_config_xml=$(cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@1385.vb_58b_86ea_fff1">
  <actions/>
  <description>A sample pipeline job created by the demo script.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps@3837.v3de5c9240516">
    <script>
pipeline {
    agent any

    stages {
        stage('Hello') {
            steps {
                echo 'Hello from Demo Pipeline!'
                sh 'date'
            }
        }
        stage('Success') {
            steps {
                echo 'Pipeline completed successfully.'
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
    # Check if job exists
    JOB_EXISTS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" \
        "${target_jenkins_url}/job/${job_name}/config.xml")

    if [ "$JOB_EXISTS_CODE" == "200" ]; then
        info "Job '${job_name}' already exists. Updating it."
        # Update existing job
        curl -k -s -X POST -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" \
            -H "${JENKINS_CRUMB}" \
            -H "Content-Type: application/xml" \
            --data-binary "${job_config_xml}" \
            "${target_jenkins_url}/job/${job_name}/config.xml"
        if [ $? -eq 0 ]; then
            info "Sample Jenkins job '${job_name}' updated successfully."
        else
            error "Failed to update sample Jenkins job '${job_name}'."
            return 1
        fi
    else
        info "Job '${job_name}' does not exist. Creating it."
        # Create new job
        curl -k -s -X POST -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" \
            -H "${JENKINS_CRUMB}" \
            -H "Content-Type: application/xml" \
            --data-binary "${job_config_xml}" \
            "${target_jenkins_url}/createItem?name=${job_name}"
        if [ $? -eq 0 ]; then
            info "Sample Jenkins job '${job_name}' created successfully."
        else
            error "Failed to create sample Jenkins job '${job_name}'."
            # Print Jenkins response for debugging if curl failed
            # response=$(curl -k -v -X POST -u "${JENKINS_API_USER}:${JENKINS_API_TOKEN}" -H "${JENKINS_CRUMB}" -H "Content-Type: application/xml" --data-binary "${job_config_xml}" "${target_jenkins_url}/createItem?name=${job_name}")
            # error "Jenkins API response: $response"
            return 1
        fi
    fi
    info "To trigger the job: ${target_jenkins_url}/job/${job_name}/build?delay=0sec"
}

# --- Validation and Output ---

validate_deployment() {
    info "Validating deployment..."
    local all_ok=true

    # Check Jenkins Nginx endpoint
    if curl -k -s --fail "${JENKINS_URL_BASE_DOCKER}/login" > /dev/null; then
        info "Jenkins Nginx endpoint (${JENKINS_URL_BASE_DOCKER}/login) is accessible."
    else
        error "Jenkins Nginx endpoint (${JENKINS_URL_BASE_DOCKER}/login) is NOT accessible."
        all_ok=false
    fi

    # Check Prometheus
    if curl -s --fail "http://localhost:9090/api/v1/status/buildinfo" > /dev/null; then
        info "Prometheus API (http://localhost:9090) is accessible."
        # Check if Prometheus is scraping Jenkins targets
        # This requires jq to parse JSON output nicely
        if command -v jq >/dev/null; then
            targets_output=$(curl -s "http://localhost:9090/api/v1/targets")
            jenkins_targets_up=$(echo "$targets_output" | jq -r '.data.activeTargets[] | select(.labels.job=="jenkins") | .health' | grep -c "up")
            if [ "$jenkins_targets_up" -ge 1 ]; then # Expecting 2 for HA, but at least 1 is good for basic check
                info "Prometheus is successfully scraping ${jenkins_targets_up} Jenkins target(s)."
            else
                warn "Prometheus does not seem to be scraping Jenkins targets successfully. Check Prometheus UI."
            fi
        else
            warn "jq is not installed. Skipping detailed Prometheus target check."
        fi
    else
        error "Prometheus API (http://localhost:9090) is NOT accessible."
        all_ok=false
    fi

    # Check Grafana
    if curl -s --fail "http://localhost:3000/api/health" > /dev/null; then
        info "Grafana API (http://localhost:3000) is accessible."
    else
        error "Grafana API (http://localhost:3000) is NOT accessible."
        all_ok=false
    fi

    if $all_ok; then
        info "Basic validation successful."
    else
        error "Some validation checks failed. Please review the logs."
    fi
}

print_access_info() {
    info "--- Access Information ---"
    echo -e "${YELLOW}Jenkins URL:${NC} ${JENKINS_URL_BASE_DOCKER}/"
    echo -e "${YELLOW}Jenkins Admin User:${NC} ${JENKINS_ADMIN_USER}"
    echo -e "${YELLOW}Jenkins Admin Password:${NC} ${JENKINS_ADMIN_PASSWORD}"
    echo -e ""
    echo -e "${YELLOW}Prometheus URL:${NC} http://localhost:9090/"
    echo -e "${YELLOW}Grafana URL:${NC} http://localhost:3000/"
    echo -e "${YELLOW}Grafana Credentials:${NC} admin / admin (or as set by GF_SECURITY_ADMIN_USER/PASSWORD)"
    echo -e ""
    echo -e "${YELLOW}Sample Jenkins Job:${NC} ${JENKINS_URL_BASE_DOCKER}/job/Sample-Demo-Pipeline/"
    info "--- End of Access Information ---"

    warn "For ${JENKINS_URL_BASE_DOCKER} (if using https://jenkins.local or similar based on self-signed cert CN):"
    warn "You might need to add an entry to your /etc/hosts file (e.g., '127.0.0.1 jenkins.local') "
    warn "and/or accept the self-signed certificate warning in your browser."
    warn "Using https://localhost should generally work after accepting the certificate warning."
}

# --- Main Execution ---
main() {
    trap cleanup_docker_resources EXIT # Ensure cleanup happens on script exit or interruption

    info "Starting Docker Demo Deployment Script..."

    check_prerequisites
    load_env # Load .env file if present

    cleanup_docker_resources # Initial cleanup before starting
    run_setup_script # Create certs, dirs

    deploy_jenkins_stack
    deploy_monitoring_stack

    wait_for_jenkins_instances
    wait_for_monitoring_services

    create_sample_jenkins_job

    validate_deployment
    print_access_info

    info "Docker Demo Deployment Completed!"
    info "You can access Jenkins at: ${JENKINS_URL_BASE_DOCKER}"
    info "To clean up, run this script again (it cleans up first) or run demo-reset.sh"

    # Remove trap for cleanup if successful completion, so user can inspect
    trap - EXIT
}

# Run main function
main
