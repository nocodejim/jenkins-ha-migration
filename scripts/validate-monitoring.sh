#!/bin/bash

# Script to validate the monitoring stack

# Exit immediately if a command exits with a non-zero status.
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

OVERALL_STATUS="PASS"
DOCKER_COMPOSE_FILE="monitoring/docker-compose.yml" # Assuming script is run from repo root

echo_pass() {
  echo -e "${GREEN}PASS: $1${NC}"
}

echo_fail() {
  echo -e "${RED}FAIL: $1${NC}"
  OVERALL_STATUS="FAIL"
}

echo_info() {
  echo -e "${YELLOW}INFO: $1${NC}"
}

# Check 1: All monitoring services are running
echo_info "1. Checking container status..."
SERVICES=("prometheus" "grafana" "alertmanager" "node-exporter" "jenkins")
ALL_RUNNING=true
for SERVICE in "${SERVICES[@]}"; do
  # Check if container is running and healthy (if healthcheck is defined)
  # For simplicity, just checking for 'Up' status. Health status can be more complex.
  if ! docker-compose -f "$DOCKER_COMPOSE_FILE" ps "$SERVICE" | grep -q "Up"; then
    echo_fail "Service $SERVICE is not running."
    ALL_RUNNING=false
  else
    echo_pass "Service $SERVICE is running."
  fi
done
if [ "$ALL_RUNNING" = false ]; then
  echo_fail "One or more services are not running. Docker PS output:"
  docker-compose -f "$DOCKER_COMPOSE_FILE" ps
fi

# Check 2: Prometheus can reach and scrape Jenkins
echo_info "2. Verifying Prometheus scrape target for Jenkins..."
# Wait a bit for Prometheus to start and scrape targets
echo_info "Waiting 30 seconds for Prometheus to initialize and scrape targets..."
sleep 30

PROMETHEUS_URL="http://localhost:9090"
# Target job name is 'jenkins', instance is 'jenkins:8080'
# The scrape path is /jenkins/prometheus
JENKINS_TARGET_URL="http://jenkins:8080/jenkins/prometheus"

# Query Prometheus for active targets, filter for the Jenkins job, and check health
# The label for the instance in Prometheus will be 'jenkins:8080'
# The job name is 'jenkins'
TARGET_HEALTH_JSON=$(curl -s -g "${PROMETHEUS_URL}/api/v1/targets?state=active" | jq -r --arg job "jenkins" --arg instance "jenkins:8080" '.data.activeTargets[] | select(.scrapePool==$job and .labels.instance==$instance)')

if [ -z "$TARGET_HEALTH_JSON" ]; then
  echo_fail "Jenkins target (jenkins:8080) not found in Prometheus active targets."
  echo_info "Attempting to curl Jenkins metrics endpoint from within a container on the network..."
  docker-compose -f "$DOCKER_COMPOSE_FILE" exec -T prometheus curl -s --fail $JENKINS_TARGET_URL > /dev/null || echo_fail "Failed to curl Jenkins metrics directly."
else
  TARGET_HEALTH=$(echo "$TARGET_HEALTH_JSON" | jq -r '.health')
  LAST_ERROR=$(echo "$TARGET_HEALTH_JSON" | jq -r '.lastError')
  if [ "$TARGET_HEALTH" = "up" ]; then
    echo_pass "Prometheus successfully scraping Jenkins target ($JENKINS_TARGET_URL)."
  else
    echo_fail "Prometheus Jenkins target ($JENKINS_TARGET_URL) is NOT healthy. Status: $TARGET_HEALTH. Last error: $LAST_ERROR"
  fi
fi


# Check 3: Test Grafana login
echo_info "3. Testing Grafana login..."
GRAFANA_URL="http://localhost:3000"
GRAFANA_USER="admin"
GRAFANA_PASS="admin"

# Attempt to login and get a session cookie
LOGIN_RESPONSE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -c cookies.txt -X POST -H "Content-Type: application/json" \
    --data "{\"user\":\"${GRAFANA_USER}\",\"password\":\"${GRAFANA_PASS}\",\"email\":\"\"}" \
    "${GRAFANA_URL}/login")

if [ "$LOGIN_RESPONSE_CODE" = "200" ] || [ "$LOGIN_RESPONSE_CODE" = "401" ]; then # Older Grafana might return 401 then 200 on auto-login
    # Now try to access a protected endpoint
    AUTH_TEST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "${GRAFANA_URL}/api/datasources")
    if [ "$AUTH_TEST_CODE" = "200" ]; then
        echo_pass "Grafana login successful (User: $GRAFANA_USER)."
    else
        echo_fail "Grafana login failed. Could not access protected endpoint. HTTP status: $AUTH_TEST_CODE."
        echo_info "Login attempt response code was: $LOGIN_RESPONSE_CODE"
    fi
else
    echo_fail "Grafana login failed. HTTP status: $LOGIN_RESPONSE_CODE."
fi
rm -f cookies.txt


# Check 4: Confirm Jenkins dashboard is loaded in Grafana
echo_info "4. Confirming Jenkins dashboard is loaded in Grafana..."
# The Jenkins dashboard JSON is 'monitoring/grafana/dashboards/jenkins-dashboard.json'
# We need to find its title or UID. Let's assume the title is "Jenkins" or similar.
# A more robust check would be to fetch the dashboard by a known UID if it's set.
# For now, search for a dashboard that might be the Jenkins one.
# The dashboard title is "Jenkins Overview" in the provided jenkins-dashboard.json
DASHBOARD_TITLE_SEARCH="Jenkins Overview"

# Use Grafana API to search for dashboards. Requires auth if not anonymous.
# Using admin credentials via Basic Auth for simplicity here.
DASHBOARD_SEARCH_RESPONSE_CODE=$(curl -s -o dashboard_search_output.json -w "%{http_code}" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    "${GRAFANA_URL}/api/search?query=${DASHBOARD_TITLE_SEARCH// /%20}") # URL encode spaces

if [ "$DASHBOARD_SEARCH_RESPONSE_CODE" = "200" ]; then
    # Check if the output (a JSON array) contains an entry with the title
    if jq -e --arg title "$DASHBOARD_TITLE_SEARCH" '.[] | select(.title == $title)' dashboard_search_output.json > /dev/null; then
        echo_pass "Grafana dashboard '$DASHBOARD_TITLE_SEARCH' is loaded."
    else
        echo_fail "Grafana dashboard '$DASHBOARD_TITLE_SEARCH' not found."
        echo_info "Dashboard search output:"
        cat dashboard_search_output.json
    fi
else
    echo_fail "Failed to query Grafana for dashboards. HTTP status: $DASHBOARD_SEARCH_RESPONSE_CODE."
fi
rm -f dashboard_search_output.json

# Final Status
echo_info "-------------------------------------------"
if [ "$OVERALL_STATUS" = "PASS" ]; then
  echo_pass "All validation checks passed!"
  exit 0
else
  echo_fail "One or more validation checks failed."
  exit 1
fi
