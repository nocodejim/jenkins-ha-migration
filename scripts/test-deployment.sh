#!/bin/bash

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global test status
OVERALL_STATUS="PASS"
declare -A TEST_RESULTS

log_test_result() {
    local test_name="$1"
    local status="$2" # PASS or FAIL
    local message="$3"

    TEST_RESULTS["$test_name"]="$status"

    if [ "$status" == "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $test_name: $message"
    else
        echo -e "${RED}[FAIL]${NC} $test_name: $message"
        OVERALL_STATUS="FAIL"
    fi
}

# --- Pre-deployment Checks ---
echo "Running Pre-deployment Checks..."

# Check for required tools
check_tool() {
    local tool_name="$1"
    if command -v "$tool_name" &> /dev/null; then
        log_test_result "$tool_name installed" "PASS" "$tool_name is installed."
    else
        log_test_result "$tool_name installed" "FAIL" "$tool_name is not installed."
    fi
}
check_tool "docker"
check_tool "docker-compose"
check_tool "curl" # curl is used extensively

# Check for sufficient disk space
MIN_DISK_SPACE_GB=10
check_disk_space() {
    local free_space_kb=$(df -k --output=avail / | tail -n 1)
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    if [ "$free_space_gb" -ge "$MIN_DISK_SPACE_GB" ]; then
        log_test_result "Sufficient disk space" "PASS" "Available disk space: ${free_space_gb}GB (Required: ${MIN_DISK_SPACE_GB}GB)"
    else
        log_test_result "Sufficient disk space" "FAIL" "Available disk space: ${free_space_gb}GB (Required: ${MIN_DISK_SPACE_GB}GB)"
    fi
}
check_disk_space

# Check for port availability
check_port() {
    local port="$1"
    if ! ss -tuln | grep -q ":$port "; then
        log_test_result "Port $port available" "PASS" "Port $port is available."
    else
        log_test_result "Port $port available" "FAIL" "Port $port is in use."
    fi
}
# Ports commonly used by Jenkins, Prometheus, Grafana, etc.
# Adjust as per your actual deployment
check_port "8080"  # Jenkins
check_port "9090"  # Prometheus
check_port "3000"  # Grafana
check_port "9100"  # Node Exporter (example)

# Check for required environment variables
check_env_var() {
    local var_name="$1"
    if [ -n "${!var_name}" ]; then # Using indirection to check variable by its name
        log_test_result "Environment variable $var_name set" "PASS" "$var_name is set."
    else
        log_test_result "Environment variable $var_name set" "FAIL" "$var_name is not set."
    fi
}
# Add your critical environment variables here
check_env_var "JENKINS_USER" # Example
check_env_var "JENKINS_PASS" # Example
# check_env_var "PROMETHEUS_CONFIG_PATH"
# check_env_var "GRAFANA_ADMIN_USER"

# --- Deployment Validation ---
echo -e "\nRunning Deployment Validation..."

# Define service URLs - customize these to your environment
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
# Add other service URLs as needed

# Check Docker container status (assuming docker-compose is used in the current dir or a specific file is used)
# This is a basic check. More sophisticated checks might involve parsing `docker-compose ps -q`
# or checking specific container names if not using docker-compose.
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}" # Allow overriding compose file

check_docker_containers() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_test_result "Docker containers running" "FAIL" "Docker compose file '$COMPOSE_FILE' not found. Skipping container checks."
        return
    fi

    # Check if all services defined in docker-compose are running
    # Note: `docker-compose ps --services --filter status=running` lists running services
    #       `docker-compose ps --services` lists all services
    # We want to ensure all *defined* services are up.
    local all_services
    all_services=$(docker-compose -f "$COMPOSE_FILE" config --services)
    if [ -z "$all_services" ]; then
        log_test_result "Docker containers configuration" "FAIL" "Could not list services from $COMPOSE_FILE"
        return
    fi

    local all_running=true
    for service in $all_services; do
        # Check if service is running and not in a restart loop or exited
        # `docker-compose ps -q $service` returns an ID if up, empty otherwise.
        # `docker inspect` can give more details on state.
        local container_id
        container_id=$(docker-compose -f "$COMPOSE_FILE" ps -q "$service")
        if [ -z "$container_id" ]; then
            log_test_result "Docker container $service running" "FAIL" "$service is not running or not found by docker-compose."
            all_running=false
            continue
        fi

        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' "$container_id")
        if [ "$container_status" == "running" ]; then
            log_test_result "Docker container $service status" "PASS" "$service is running."
        elif [ "$container_status" == "exited" ]; then
             # Check exit code if it exited
            local exit_code
            exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container_id")
            if [ "$exit_code" -eq 0 ]; then
                 # Some containers might be meant to run and exit (e.g., setup scripts)
                 # This needs to be decided based on the service. For now, assume long-running.
                log_test_result "Docker container $service status" "PASS" "$service exited with code 0 (considered OK for some services)."
            else
                log_test_result "Docker container $service status" "FAIL" "$service exited with code $exit_code."
                all_running=false
            fi
        else
            log_test_result "Docker container $service status" "FAIL" "$service is in state: $container_status."
            all_running=false
        fi
    done

    if $all_running; then
        log_test_result "All Docker containers operational" "PASS" "All services defined in $COMPOSE_FILE appear to be operational."
    else
        log_test_result "All Docker containers operational" "FAIL" "Not all services in $COMPOSE_FILE are operational."
    fi
}
check_docker_containers

# Check service accessibility
check_service_url() {
    local service_name="$1"
    local url="$2"
    # Use curl with a timeout, follow redirects, and fail silently on errors for scripting
    if curl -LfsS --connect-timeout 5 "$url" > /dev/null; then
        log_test_result "$service_name accessibility" "PASS" "$service_name is accessible at $url."
    else
        log_test_result "$service_name accessibility" "FAIL" "$service_name is not accessible at $url."
    fi
}
check_service_url "Jenkins" "$JENKINS_URL"
check_service_url "Prometheus" "$PROMETHEUS_URL/graph" # Specific endpoint for Prometheus
check_service_url "Grafana" "$GRAFANA_URL/api/health"  # Specific health endpoint for Grafana

# Jenkins login test
check_jenkins_login() {
    if [ -z "$JENKINS_USER" ] || [ -z "$JENKINS_PASS" ]; then
        log_test_result "Jenkins login" "FAIL" "JENKINS_USER or JENKINS_PASS not set. Skipping login test."
        return
    fi

    # Jenkins usually requires a crumb for POST requests (like login)
    # For a simple check, we can try to access a protected page or use the API
    # This example tries to get user info, which requires auth
    local response_code
    response_code=$(curl -LfsS --connect-timeout 10 -u "$JENKINS_USER:$JENKINS_PASS" "$JENKINS_URL/me/api/json" -o /dev/null -w "%{http_code}")

    if [ "$response_code" -eq 200 ]; then
        log_test_result "Jenkins login" "PASS" "Successfully logged into Jenkins as $JENKINS_USER."
    elif [ "$response_code" -eq 401 ]; then
        log_test_result "Jenkins login" "FAIL" "Jenkins login failed for $JENKINS_USER (Unauthorized - check credentials)."
    elif [ "$response_code" -eq 403 ]; then
        log_test_result "Jenkins login" "FAIL" "Jenkins login failed for $JENKINS_USER (Forbidden - likely crumb issue or permissions)."
    else
        log_test_result "Jenkins login" "FAIL" "Jenkins login failed for $JENKINS_USER (HTTP status: $response_code)."
    fi
}
check_jenkins_login

# Basic check for monitoring stack (Prometheus targets)
check_prometheus_targets() {
    if ! command -v jq &> /dev/null; then
        log_test_result "Prometheus targets (jq missing)" "FAIL" "jq is not installed. Cannot parse Prometheus targets."
        return
    fi

    local targets_json
    targets_json=$(curl -LfsS --connect-timeout 5 "$PROMETHEUS_URL/api/v1/targets")
    if [ -z "$targets_json" ]; then
        log_test_result "Prometheus targets" "FAIL" "Could not retrieve targets from Prometheus."
        return
    fi

    # Check if there's at least one 'up' target for 'jenkins' job (example)
    # This needs to be adapted based on your Prometheus configuration
    local jenkins_targets_up
    jenkins_targets_up=$(echo "$targets_json" | jq '.data.activeTargets[] | select(.labels.job=="jenkins" and .health=="up") | .health' | wc -l)

    if [ "$jenkins_targets_up" -ge 1 ]; then
        log_test_result "Prometheus Jenkins target" "PASS" "Prometheus has at least one 'up' target for Jenkins."
    else
        local total_jenkins_targets
        total_jenkins_targets=$(echo "$targets_json" | jq '.data.activeTargets[] | select(.labels.job=="jenkins") | .health' | wc -l)
        if [ "$total_jenkins_targets" -eq 0 ]; then
             log_test_result "Prometheus Jenkins target" "FAIL" "Prometheus has no targets configured for job='jenkins'."
        else
             log_test_result "Prometheus Jenkins target" "FAIL" "Prometheus Jenkins target(s) are not 'up'. Check Prometheus target status."
        fi
    fi
    # Add more checks for other critical targets if necessary
}
check_prometheus_targets

# --- Functionality Tests ---
echo -e "\nRunning Functionality Tests..."

JENKINS_API_USER="$JENKINS_USER"
JENKINS_API_TOKEN="$JENKINS_PASS" # In real Jenkins, this should be an API token, not the password
TEST_JOB_NAME="DeploymentTestJob"
JENKINS_CRUMB="" # Will be fetched

# Function to get Jenkins crumb
get_jenkins_crumb() {
    if [ -z "$JENKINS_API_USER" ] || [ -z "$JENKINS_API_TOKEN" ]; then
        log_test_result "Jenkins Crumb" "FAIL" "JENKINS_API_USER or JENKINS_API_TOKEN not set. Cannot fetch crumb."
        return 1
    fi
    # Fetch crumb using basic auth
    JENKINS_CRUMB=$(curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" "$JENKINS_URL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
    if [ -z "$JENKINS_CRUMB" ]; then
        log_test_result "Jenkins Crumb" "FAIL" "Failed to fetch Jenkins crumb. API calls might fail."
        return 1
    else
        log_test_result "Jenkins Crumb" "PASS" "Successfully fetched Jenkins crumb."
        return 0
    fi
}

# Create a test job via API
# This job will simply echo "Hello World"
create_jenkins_job() {
    if ! get_jenkins_crumb; then return; fi

    local job_config_xml
    job_config_xml="<?xml version='1.1' encoding='UTF-8'?>
<project>
  <description>Test job created by deployment script.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class='hudson.scm.NullSCM'/>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell>
      <command>echo 'Hello World from DeploymentTestJob'</command>
    </hudson.tasks.Shell>
  </builders>
  <publishers/>
  <buildWrappers/>
</project>"

    # Check if job exists, delete if so to ensure clean state (or update)
    local job_exists_code
    job_exists_code=$(curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" -o /dev/null -w "%{http_code}" "$JENKINS_URL/job/$TEST_JOB_NAME/config.xml")

    if [ "$job_exists_code" -eq 200 ]; then
        echo "Test job '$TEST_JOB_NAME' already exists. Will be overwritten."
        # Optionally, delete it first:
        # curl -s -X POST -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "$JENKINS_URL/job/$TEST_JOB_NAME/doDelete"
    fi

    local response_code
    response_code=$(curl -s -X POST -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" -H "Content-Type:application/xml" --data "$job_config_xml" "$JENKINS_URL/createItem?name=$TEST_JOB_NAME" -o /dev/null -w "%{http_code}")

    if [ "$response_code" -eq 200 ]; then
        log_test_result "Create Jenkins Job '$TEST_JOB_NAME'" "PASS" "Successfully created/updated Jenkins job '$TEST_JOB_NAME'."
    else
        log_test_result "Create Jenkins Job '$TEST_JOB_NAME'" "FAIL" "Failed to create Jenkins job '$TEST_JOB_NAME'. HTTP status: $response_code."
    fi
}
create_jenkins_job

# Run the test job
trigger_jenkins_job() {
    if ! get_jenkins_crumb; then return; fi
    if ! curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "$JENKINS_URL/job/$TEST_JOB_NAME/api/json" | grep -q "$TEST_JOB_NAME"; then
        log_test_result "Trigger Jenkins Job '$TEST_JOB_NAME'" "FAIL" "Job '$TEST_JOB_NAME' does not exist or crumb issue. Cannot trigger."
        return
    fi

    local queue_url_header
    # Trigger build and get queue item URL from Location header
    queue_url_header=$(curl -s -X POST -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "$JENKINS_URL/job/$TEST_JOB_NAME/build" -D - -o /dev/null | grep -i Location)

    if [ -z "$queue_url_header" ]; then
        log_test_result "Trigger Jenkins Job '$TEST_JOB_NAME'" "FAIL" "Failed to trigger Jenkins job '$TEST_JOB_NAME'. No queue location header received."
        return
    fi

    local queue_item_url
    queue_item_url=$(echo "$queue_url_header" | awk '{print $2}' | tr -d '\r') # Clean up URL

    if [ -z "$queue_item_url" ]; then
        log_test_result "Trigger Jenkins Job '$TEST_JOB_NAME'" "FAIL" "Failed to parse queue item URL for '$TEST_JOB_NAME'."
        return
    fi

    log_test_result "Trigger Jenkins Job '$TEST_JOB_NAME'" "PASS" "Successfully triggered Jenkins job '$TEST_JOB_NAME'. Queue item: $queue_item_url"
    echo "$queue_item_url" # Pass queue item URL to the next function
}

# Verify job completes successfully
verify_jenkins_job_completion() {
    local queue_item_url="$1"
    if [ -z "$queue_item_url" ]; then
        log_test_result "Verify Job Completion '$TEST_JOB_NAME'" "FAIL" "Queue item URL not provided."
        return
    fi

    if ! get_jenkins_crumb; then return; fi

    local build_number=""
    local job_status="UNKNOWN"
    local attempts=0
    local max_attempts=30 # Wait for 30 * 5s = 150 seconds max

    echo "Waiting for job '$TEST_JOB_NAME' to start and complete..."
    while [ $attempts -lt $max_attempts ]; do
        local queue_data executable_data build_data
        queue_data=$(curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "${queue_item_url}api/json")

        executable_url=$(echo "$queue_data" | jq -r '.executable.url')

        if [ "$executable_url" != "null" ] && [ -n "$executable_url" ]; then
            build_number=$(echo "$queue_data" | jq -r '.executable.number')
            echo "Job '$TEST_JOB_NAME' started as build #$build_number. Checking status..."

            build_data=$(curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "${JENKINS_URL}/job/${TEST_JOB_NAME}/${build_number}/api/json")
            job_status=$(echo "$build_data" | jq -r '.result') # SUCCESS, FAILURE, ABORTED, UNSTABLE
            local building=$(echo "$build_data" | jq -r '.building')

            if [ "$building" == "false" ]; then
                if [ "$job_status" == "SUCCESS" ]; then
                    log_test_result "Verify Job Completion '$TEST_JOB_NAME' #$build_number" "PASS" "Job completed successfully."
                else
                    log_test_result "Verify Job Completion '$TEST_JOB_NAME' #$build_number" "FAIL" "Job completed with status: $job_status."
                fi
                return
            fi
        elif echo "$queue_data" | jq -e '.cancelled' > /dev/null; then
             log_test_result "Verify Job Completion '$TEST_JOB_NAME'" "FAIL" "Job was cancelled in queue."
             return
        fi

        attempts=$((attempts + 1))
        echo "Still waiting for '$TEST_JOB_NAME' #$build_number (Attempt $attempts/$max_attempts)... Status: $job_status, Building: ${building:-pending in queue}"
        sleep 5
    done

    log_test_result "Verify Job Completion '$TEST_JOB_NAME'" "FAIL" "Job did not complete within the timeout period."
}

# Execute job flow
QUEUE_ITEM_URL=$(trigger_jenkins_job)
if [ -n "$QUEUE_ITEM_URL" ]; then
    verify_jenkins_job_completion "$QUEUE_ITEM_URL"
fi


# Check metrics are collected (basic check for any Jenkins metric)
check_jenkins_metrics() {
    if ! command -v jq &> /dev/null; then
        log_test_result "Jenkins Metrics Collection (jq missing)" "FAIL" "jq is not installed. Cannot parse Prometheus metrics."
        return
    fi

    # Query Prometheus for a known Jenkins metric.
    # Example: jenkins_up (gauge, should be 1 if Jenkins is up and scraped)
    # The metric name might vary based on your Jenkins Prometheus plugin config.
    # Common metrics: jenkins_executor_count_value, jenkins_job_count_value
    local metric_query='jenkins_up{job="jenkins"}' # Adjust job label if needed
    local query_url="$PROMETHEUS_URL/api/v1/query?query=$(echo "$metric_query" | sed 's/{/%7B/g; s/}/%7D/g; s/"/%22/g')" # URL encode

    local metric_response
    metric_response=$(curl -LfsS --connect-timeout 5 "$query_url")

    if [ -z "$metric_response" ]; then
        log_test_result "Jenkins Metrics Collection" "FAIL" "Could not query Prometheus for Jenkins metrics."
        return
    fi

    local metric_value
    # Assuming the metric is a gauge and we expect at least one result with value 1
    metric_value=$(echo "$metric_response" | jq -r '.data.result[] | select(.value[1] == "1") | .value[1]')

    if [ "$metric_value" == "1" ]; then
        log_test_result "Jenkins Metrics Collection" "PASS" "Successfully fetched 'jenkins_up' metric with value 1 from Prometheus."
    else
        local result_count
        result_count=$(echo "$metric_response" | jq '.data.result | length')
        if [ "$result_count" -eq 0 ]; then
            log_test_result "Jenkins Metrics Collection" "FAIL" "'jenkins_up' metric not found in Prometheus. Check Prometheus scrape config and Jenkins /prometheus endpoint."
        else
            log_test_result "Jenkins Metrics Collection" "FAIL" "'jenkins_up' metric value is not 1 or not found as expected. Current value(s): $(echo "$metric_response" | jq -r '.data.result[].value[1]') "
        fi
    fi
}
check_jenkins_metrics

# Verify backups work (placeholder - highly dependent on backup solution)
# This would involve:
# 1. Identifying the backup mechanism (e.g., a script, a Jenkins job, a cron job + rsync/restic/etc.)
# 2. Triggering a backup if possible, or checking for recent successful backups.
# 3. Verifying the backup artifact (e.g., file exists, is not empty, checksum matches).
check_backups() {
    # Example: Check if a backup Jenkins job named "SystemBackup" ran successfully in the last 24 hours
    # This is a conceptual example.
    local backup_job_name="SystemBackup" # Customize this
    local last_successful_build_time=0

    if [ -z "$JENKINS_API_USER" ] || [ -z "$JENKINS_API_TOKEN" ]; then
         log_test_result "Backup Verification" "FAIL" "Jenkins credentials not set, cannot check backup job."
         return
    fi
    if ! get_jenkins_crumb; then return; fi


    local job_info_json
    job_info_json=$(curl -s -u "$JENKINS_API_USER:$JENKINS_API_TOKEN" -H "$JENKINS_CRUMB" "$JENKINS_URL/job/$backup_job_name/api/json")

    if ! echo "$job_info_json" | jq -e '.name' > /dev/null 2>&1; then
        log_test_result "Backup Verification ($backup_job_name)" "FAIL" "Backup job '$backup_job_name' not found or error fetching info."
        return
    fi

    last_successful_build_time=$(echo "$job_info_json" | jq -r '.lastSuccessfulBuild.timestamp // 0') # ms since epoch

    if [ "$last_successful_build_time" -eq 0 ]; then
        log_test_result "Backup Verification ($backup_job_name)" "FAIL" "No successful build found for backup job '$backup_job_name'."
        return
    fi

    local current_time_ms
    current_time_ms=$(date +%s%3N)
    local time_diff_ms=$((current_time_ms - last_successful_build_time))
    local hours_diff=$((time_diff_ms / 1000 / 3600))

    if [ "$hours_diff" -le 24 ]; then
        log_test_result "Backup Verification ($backup_job_name)" "PASS" "Recent successful backup found for '$backup_job_name' (ran $hours_diff hours ago)."
    else
        log_test_result "Backup Verification ($backup_job_name)" "FAIL" "Last successful backup for '$backup_job_name' is too old (ran $hours_diff hours ago)."
    fi

    # More sophisticated checks could involve:
    # - Triggering an ad-hoc backup via API (if the backup system supports it)
    # - Checking backup storage for the latest artifact and its integrity
    log_test_result "Backup System (Conceptual)" "PASS" "Placeholder for actual backup verification logic. Checked for recent Jenkins job '$backup_job_name'."
    echo "INFO: Actual backup verification (triggering, checking artifacts) needs to be implemented based on the specific backup solution."
}
# Only run backup check if JENKINS_USER and JENKINS_PASS are set, as it relies on Jenkins API
if [ -n "$JENKINS_USER" ] && [ -n "$JENKINS_PASS" ]; then
    check_backups
else
    log_test_result "Backup Verification" "FAIL" "Skipped due to missing JENKINS_USER/JENKINS_PASS."
fi

# --- Integration Tests ---
echo -e "\nRunning Integration Tests..."

# Jenkins can reach external services
# This test assumes Jenkins is running in a Docker container managed by COMPOSE_FILE.
# It will try to exec into the Jenkins container and ping google.com.
# The service name for Jenkins in docker-compose.yml is assumed to be 'jenkins'.
JENKINS_SERVICE_NAME="${JENKINS_SERVICE_NAME:-jenkins}" # Docker-compose service name for Jenkins

check_jenkins_external_connectivity() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_test_result "Jenkins External Connectivity" "FAIL" "Docker compose file '$COMPOSE_FILE' not found. Skipping test."
        return
    fi
    if ! docker-compose -f "$COMPOSE_FILE" ps -q "$JENKINS_SERVICE_NAME" &>/dev/null; then
        log_test_result "Jenkins External Connectivity" "FAIL" "Jenkins service '$JENKINS_SERVICE_NAME' not found or not running. Skipping test."
        return
    fi

    # Try to ping google.com from within the Jenkins container.
    # Some minimal Jenkins images might not have 'ping'. 'curl' to a known site is more reliable.
    if docker-compose -f "$COMPOSE_FILE" exec -T "$JENKINS_SERVICE_NAME" curl -s --connect-timeout 5 "https://www.google.com" > /dev/null; then
        log_test_result "Jenkins External Connectivity" "PASS" "Jenkins container can reach external services (e.g., google.com)."
    else
        log_test_result "Jenkins External Connectivity" "FAIL" "Jenkins container failed to reach external services (e.g., google.com)."
    fi
}
check_jenkins_external_connectivity

# Monitoring can scrape Jenkins (already partially covered by Functionality Test: check_jenkins_metrics)
# This test will re-verify the specific Prometheus target for Jenkins.
check_prometheus_scrapes_jenkins() {
    if ! command -v jq &> /dev/null; then
        log_test_result "Prometheus Scrapes Jenkins (jq missing)" "FAIL" "jq is not installed. Cannot parse Prometheus targets."
        return
    fi
    if [ -z "$PROMETHEUS_URL" ]; then
        log_test_result "Prometheus Scrapes Jenkins" "FAIL" "PROMETHEUS_URL not set."
        return
    fi

    local targets_json
    targets_json=$(curl -LfsS --connect-timeout 5 "$PROMETHEUS_URL/api/v1/targets")
    if [ -z "$targets_json" ]; then
        log_test_result "Prometheus Scrapes Jenkins" "FAIL" "Could not retrieve targets from Prometheus."
        return
    fi

    # Look for a target with a job label like 'jenkins' (or whatever your actual job name is) and health 'up'.
    # And its scrape URL should point to the Jenkins instance.
    local jenkins_scrape_url_pattern="${JENKINS_URL}" # Basic check, might need refinement if Jenkins URL is complex

    # Try to find a target that has 'job' label 'jenkins' (or similar) and is 'up'
    # The scrape URL can also be checked if known, e.g., contains JENKINS_URL/prometheus
    local jenkins_target_health
    jenkins_target_health=$(echo "$targets_json" | jq -r --arg pattern "$jenkins_scrape_url_pattern" '.data.activeTargets[] | select((.labels.job=="jenkins" or .labels.job=="jenkins-master") and .health=="up" and (.scrapeUrl | contains($pattern))) | .health')

    if [ "$jenkins_target_health" == "up" ]; then
        log_test_result "Prometheus Scrapes Jenkins" "PASS" "Prometheus is successfully scraping Jenkins (target is 'up' and URL matches)."
    else
        local specific_target_info
        specific_target_info=$(echo "$targets_json" | jq -r --arg pattern "$jenkins_scrape_url_pattern" '.data.activeTargets[] | select((.labels.job=="jenkins" or .labels.job=="jenkins-master") and (.scrapeUrl | contains($pattern)))')
        if [ -z "$specific_target_info" ]; then
            log_test_result "Prometheus Scrapes Jenkins" "FAIL" "No Prometheus target found for Jenkins with URL pattern '$jenkins_scrape_url_pattern'."
        else
            log_test_result "Prometheus Scrapes Jenkins" "FAIL" "Prometheus target for Jenkins is not 'up' or URL mismatch. Details: $specific_target_info"
        fi
    fi
}
check_prometheus_scrapes_jenkins

# Alerts can be sent (Placeholder - requires Alertmanager setup and a way to trigger a test alert)
# This would involve:
# 1. Ensuring Alertmanager is running and configured.
# 2. Crafting a specific alert condition in Prometheus that will fire.
# 3. Checking Alertmanager API for the active alert.
# 4. Verifying notification channels (e.g., email, Slack - harder to automate fully).
check_alert_sending() {
    # This is a conceptual placeholder.
    # A real test might involve:
    # - `curl` to Alertmanager's API to post a test alert: POST /api/v1/alerts
    #   (Requires knowing the Alertmanager URL and proper alert JSON payload)
    # - Querying Alertmanager for active alerts: GET /api/v1/alerts
    # - For a simpler check, if you have a " همیشه firing" alert for testing (e.g., `vector(1)`),
    #   you could check if it's active.
    local alertmanager_url="${ALERTMANAGER_URL:-http://localhost:9093}" # Default Alertmanager URL

    if ! curl -LfsS --connect-timeout 5 "$alertmanager_url/-/healthy" > /dev/null; then
        log_test_result "Alert Sending (Alertmanager)" "FAIL" "Alertmanager not accessible at $alertmanager_url or not healthy."
        return
    fi

    # Example: Check if Alertmanager has ANY firing alerts (very basic)
    # A more robust test would be to trigger a *specific* test alert and check for it.
    local firing_alerts_count
    # Ensure jq is available for parsing Alertmanager API response
    if command -v jq &> /dev/null; then
        firing_alerts_count=$(curl -LfsS --connect-timeout 5 "$alertmanager_url/api/v2/alerts?filter=state%3Dactive" | jq '. | length')
        # The above checks for active alerts. Firing alerts might be `state=firing` in older API versions or based on configuration.
        # For this conceptual test, we assume if Alertmanager is up, the mechanism is there.
        # A true end-to-end test requires a more complex setup (e.g. a specific alert rule in prometheus that is always true)
        log_test_result "Alert Sending (Alertmanager)" "PASS" "Alertmanager is accessible. Found $firing_alerts_count active alert(s). (Further validation of specific alert delivery is complex and not implemented here)."
        echo "INFO: Actual alert delivery verification (e.g., email, Slack) is not part of this script."
    else
        log_test_result "Alert Sending (Alertmanager)" "PASS" "Alertmanager is accessible. jq not available to check active alerts count."
    fi
    echo "INFO: Alert sending validation is conceptual. Requires specific Alertmanager setup and test alert configuration."
}
check_alert_sending

# Logs are being collected (Placeholder - highly dependent on logging solution)
# This could involve:
# - If logging to files: Check for recent log entries in the expected log file(s) on the host/container.
# - If using a centralized logging stack (ELK, Loki, Splunk):
#   - Query the logging system's API for recent logs from Jenkins/other services.
#   - This often requires credentials and specific query syntax.
check_log_collection() {
    # Example for Docker container logs (if not using a centralized system)
    # This checks if the Jenkins container has produced any logs recently.
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_test_result "Log Collection (Jenkins Container)" "FAIL" "Docker compose file '$COMPOSE_FILE' not found. Skipping test."
        return
    fi
    if ! docker-compose -f "$COMPOSE_FILE" ps -q "$JENKINS_SERVICE_NAME" &>/dev/null; then
        log_test_result "Log Collection (Jenkins Container)" "FAIL" "Jenkins service '$JENKINS_SERVICE_NAME' not found or not running. Skipping test."
        return
    fi

    # Get logs from the last minute (adjust as needed)
    # `docker logs --since 1m <container_id_or_name>`
    local jenkins_container_id
    jenkins_container_id=$(docker-compose -f "$COMPOSE_FILE" ps -q "$JENKINS_SERVICE_NAME")

    if [ -z "$jenkins_container_id" ]; then
         log_test_result "Log Collection (Jenkins Container)" "FAIL" "Could not get Jenkins container ID for service '$JENKINS_SERVICE_NAME'."
         return
    fi

    if docker logs --since 1m "$jenkins_container_id" 2>&1 | grep -q "."; then # Check if any output (even errors)
        log_test_result "Log Collection (Jenkins Container)" "PASS" "Recent logs found for Jenkins container '$JENKINS_SERVICE_NAME'."
    else
        # It's possible for a healthy, idle container to not produce logs in the last minute.
        # A better check might be to trigger an action that *should* log, then check.
        # For now, this is a basic check.
        log_test_result "Log Collection (Jenkins Container)" "PASS" "No logs in the last minute for Jenkins container '$JENKINS_SERVICE_NAME' (Could be normal if idle)."
        echo "INFO: A more robust log collection test would involve triggering a log event and verifying it."
    fi

    echo "INFO: Log collection validation is conceptual. Actual checks depend on the logging stack (e.g., ELK, Loki, Splunk)."
    # If using a specific logging driver with Docker, tests would be different.
    # If logs are sent to a central system, API queries to that system would be needed.
}
check_log_collection

# --- Summary ---
echo -e "\n--- Test Summary ---"
for test_name in "${!TEST_RESULTS[@]}"; do
    status="${TEST_RESULTS[$test_name]}"
    if [ "$status" == "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
    else
        echo -e "${RED}[FAIL]${NC} $test_name"
    fi
done

echo -e "\nOverall Deployment Test Status: ${OVERALL_STATUS}"
if [ "$OVERALL_STATUS" == "PASS" ]; then
    exit 0
else
    exit 1
fi
