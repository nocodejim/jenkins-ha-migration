#!/bin/bash
set -euo pipefail

# Placeholder functions
run_tests() {
    echo "INFO: Running tests..."
    echo "INFO: Running standard test suite (make test)..."
    if make test; then
        echo "SUCCESS: Standard tests passed."
    else
        echo "ERROR: Standard tests failed. Please check the output above."
        exit 1
    fi

    echo "INFO: Running security tests (make test-security)..."
    if make test-security; then
        echo "SUCCESS: Security tests passed."
    else
        # Considering this a "final-check", a security test failure might be critical
        echo "ERROR: Security tests failed. Please review the output above."
        # Decide if this should be a hard exit or a warning. For now, let's make it a hard exit.
        exit 1
    fi
    echo "SUCCESS: All tests passed."
}

generate_deployment_report() {
    echo "INFO: Generating deployment report (deployment_report.txt)..."
    local report_file="deployment_report.txt"
    local deployment_type=""
    local k8s_namespace="jenkins-prod" # Default, can be overridden by user

    # Determine deployment type
    while true; do
        read -r -p "Is this a 'docker' or 'kubernetes' deployment? " dtype
        case "$dtype" in
            docker|kubernetes)
                deployment_type=$dtype
                break
                ;;
            *)
                echo "Invalid input. Please enter 'docker' or 'kubernetes'."
                ;;
        esac
    done

    if [ "$deployment_type" == "kubernetes" ]; then
        read -r -p "Enter the Kubernetes namespace (default: $k8s_namespace): " ns_input
        if [ -n "$ns_input" ]; then
            k8s_namespace=$ns_input
        fi
    fi

    # Start report
    {
        echo "Deployment Report - $(date)"
        echo "========================================"
        echo "Deployment Type: $deployment_type"
        if [ "$deployment_type" == "kubernetes" ]; then
            echo "Kubernetes Namespace: $k8s_namespace"
        fi
        echo ""

        # --- Service URLs ---
        echo "--- Service URLs ---"
        if [ "$deployment_type" == "docker" ]; then
            echo "Jenkins URL: Typically http://localhost:8080 (Verify this)"
            echo "Grafana URL: Typically http://localhost:3000 (Verify this)"
            echo "Prometheus URL: Typically http://localhost:9090 (Verify this)"
        else # kubernetes
            echo "Jenkins URL: Obtain using 'kubectl get ingress -n $k8s_namespace' or 'kubectl get svc -n $k8s_namespace'"
            echo "Grafana URL: Obtain by checking Grafana service (e.g., 'kubectl get svc -n monitoring prometheus-grafana') or via port-forward 'kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80'"
            echo "Prometheus URL: Obtain by checking Prometheus service (e.g., 'kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus') or via port-forward 'kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090'"
        fi
        echo "MANUAL STEP: Please verify and record the exact URLs above."
        echo ""

        # --- Credentials ---
        echo "--- Credentials ---"
        if [ "$deployment_type" == "docker" ]; then
            echo "Jenkins Admin Credentials: Check your .env file for JENKINS_ADMIN_USER and JENKINS_ADMIN_PASSWORD."
        else # kubernetes
            echo "Jenkins Admin Credentials: Check your values.yaml (e.g., jenkins.adminPassword) or the relevant Kubernetes secret (e.g., 'kubectl get secret <jenkins-secret-name> -n $k8s_namespace -o jsonpath=\"{.data.jenkins-admin-password}\" | base64 --decode')."
        fi
        echo "Grafana Admin Credentials: Default is often admin/admin. If changed, refer to your configuration (e.g. values.yaml for K8s monitoring stack)."
        echo "IMPORTANT: Securely fetch and note these credentials. Do not store plaintext passwords in insecure locations."
        echo ""

        # --- Health Status ---
        echo "--- Health Status ---"
        if [ "$deployment_type" == "docker" ]; then
            echo "Run 'docker-compose ps' in the 'docker-compose' directory to check service status."
            echo "Output of 'docker-compose ps':"
            (cd docker-compose && docker-compose ps) || echo "  Could not run 'docker-compose ps'. Ensure you are in the project root and Docker is running."
        else # kubernetes
            echo "Run 'kubectl get pods,svc,ingress -n $k8s_namespace' to check status of Jenkins components."
            echo "Output of 'kubectl get pods,svc,ingress -n $k8s_namespace':"
            kubectl get pods,svc,ingress -n "$k8s_namespace" || echo "  Could not run kubectl commands. Ensure kubectl is configured for the correct cluster."
            echo ""
            echo "Run 'kubectl get pods,svc -n monitoring' (or your monitoring namespace) for monitoring stack status."
            kubectl get pods,svc -n monitoring || echo "  Could not get monitoring stack status. Check namespace if different."
        fi
        echo "Further health details can be found in Grafana dashboards."
        echo ""

        # --- Resource Usage ---
        echo "--- Resource Usage ---"
        if [ "$deployment_type" == "docker" ]; then
            echo "For a snapshot of Docker container resource usage, run 'docker stats --no-stream \$(docker-compose -f docker-compose/docker-compose.yml ps -q)'"
            echo "Consider running 'docker stats' in a separate terminal for live monitoring."
        else # kubernetes
            echo "Run 'kubectl top pods -n $k8s_namespace' for Jenkins pod resource usage."
            echo "Run 'kubectl top pods -n monitoring' for monitoring pod resource usage."
            echo "Output of 'kubectl top pods -n $k8s_namespace':"
            kubectl top pods -n "$k8s_namespace" || echo "  Could not run 'kubectl top pods'. Ensure metrics-server is installed in your cluster."
        fi
        echo "Historical resource usage is available in Prometheus/Grafana."
        echo ""

        # --- Configuration Summary ---
        echo "--- Configuration Summary ---"
        if [ "$deployment_type" == "docker" ]; then
            echo "Main configuration files:"
            echo "  - docker-compose/docker-compose.yml"
            echo "  - .env (for environment-specific settings like credentials, paths)"
            echo "  - docker-compose/nginx/nginx.conf (if applicable)"
            echo "  - docker-compose/monitoring/prometheus/prometheus.yml (if applicable)"
        else # kubernetes
            echo "Main configuration files/sources:"
            echo "  - kubernetes/helm/values.yaml (and any overrides like values-prod.yaml)"
            echo "  - Kubernetes manifests generated by Helm (view with 'helm get manifest jenkins -n $k8s_namespace')"
            echo "  - ConfigMaps and Secrets in namespace '$k8s_namespace' (e.g., 'kubectl get configmaps -n $k8s_namespace')"
            echo "  - Prometheus Operator configurations for monitoring (ServiceMonitors, PrometheusRules in 'monitoring' namespace)"
        fi
        echo ""
        echo "Report generation complete."
    } > "$report_file"

    echo "SUCCESS: Deployment report generated at $report_file"
}

create_demo_ready_md() {
    echo "INFO: Creating DEMO_READY.md..."
    local md_file="DEMO_READY.md"
    local k8s_namespace_placeholder="<your-k8s-namespace>" # Placeholder, user should replace this
    local jenkins_deployment_placeholder="<jenkins-deployment-name>" # Placeholder for K8s deployment name

    # Try to get namespace from deployment_report.txt if it exists
    if [ -f "deployment_report.txt" ]; then
        # Attempt to extract namespace if it's a Kubernetes deployment
        ns_from_report=$(grep "Kubernetes Namespace:" deployment_report.txt | awk '{print $3}')
        if [ -n "$ns_from_report" ]; then
            k8s_namespace_placeholder=$ns_from_report
        fi
    fi


    {
        echo "# DEMO_READY Checklist & Guide"
        echo ""
        echo "This document provides quick access links, emergency commands, a demo script, and fallback options for your Jenkins HA Migration demo."
        echo ""
        echo "## 🚦 Pre-Demo Check:"
        echo "- [ ] Verify all services are running (use 'docker-compose ps' or 'kubectl get pods -n $k8s_namespace_placeholder')."
        echo "- [ ] Confirm Jenkins UI is accessible and responsive."
        echo "- [ ] Confirm Grafana UI is accessible and showing metrics."
        echo "- [ ] Log in to Jenkins with demo user credentials."
        echo "- [ ] Ensure sample job(s) are configured and ready to run."
        echo "- [ ] Clear any old/test build history if needed for a clean demo."
        echo "- [ ] Have `deployment_report.txt` handy for specific URLs/details."
        echo ""
        echo "## 🔗 Quick Access Links"
        echo ""
        echo "*   **Jenkins URL:** \`[FILL_IN_JENKINS_URL_HERE]\` (See \`deployment_report.txt\`)"
        echo "*   **Grafana URL:** \`[FILL_IN_GRAFANA_URL_HERE]\` (See \`deployment_report.txt\`)"
        echo "*   **Prometheus URL:** \`[FILL_IN_PROMETHEUS_URL_HERE]\` (See \`deployment_report.txt\`)"
        echo "*   **Project Repository:** \`[LINK_TO_YOUR_GITHUB_REPO]\`"
        echo ""
        echo "## ⚠️ Emergency Commands"
        echo ""
        echo "### Docker Compose Environment"
        echo "*   **Stop all services:** \`docker-compose down\` (in \`docker-compose/\` directory)"
        echo "*   **Start all services:** \`docker-compose up -d\` (in \`docker-compose/\` directory)"
        echo "*   **Restart a specific service (e.g., jenkins):** \`docker-compose restart jenkins\`"
        echo "*   **View logs for a service (e.g., jenkins):** \`docker-compose logs -f jenkins\`"
        echo ""
        echo "### Kubernetes Environment (namespace: \`$k8s_namespace_placeholder\`)"
        echo "*   **View Jenkins pods:** \`kubectl get pods -n $k8s_namespace_placeholder -l app.kubernetes.io/name=jenkins\`"
        echo "*   **View Jenkins logs (first pod):** \`kubectl logs -f \$(kubectl get pods -n $k8s_namespace_placeholder -l app.kubernetes.io/name=jenkins -o jsonpath='{.items[0].metadata.name}') -n $k8s_namespace_placeholder\`"
        echo "*   **Restart Jenkins deployment (graceful):**"
        echo "    \`kubectl rollout restart deployment $jenkins_deployment_placeholder -n $k8s_namespace_placeholder\` (Replace \`$jenkins_deployment_placeholder\` with actual name, e.g., 'jenkins')"
        echo "*   **Scale Jenkins down to 0 (emergency stop):**"
        echo "    \`kubectl scale deployment $jenkins_deployment_placeholder --replicas=0 -n $k8s_namespace_placeholder\`"
        echo "*   **Scale Jenkins back up (after emergency stop):**"
        echo "    \`kubectl scale deployment $jenkins_deployment_placeholder --replicas=<original_replica_count> -n $k8s_namespace_placeholder\` (e.g., replicas=2)"
        echo "*   **Uninstall Jenkins Helm release (if installed via Helm, 'jenkins' is release name):**"
        echo "    \`helm uninstall jenkins -n $k8s_namespace_placeholder\`"
        echo ""
        echo "## 📝 Demo Script Outline"
        echo ""
        echo "1.  **Introduction (2 min)**"
        echo "    *   Briefly introduce the project: Jenkins HA Migration."
        echo "    *   Problem: Legacy Windows Jenkins, need for modernization, HA, scalability."
        echo "    *   Solution: Containerized Jenkins (Docker/K8s), monitoring, automated backups."
        echo ""
        echo "2.  **Show Jenkins UI & Basic Functionality (5 min)**"
        echo "    *   Access Jenkins via its URL."
        echo "    *   Log in (if required for demo)."
        echo "    *   Show the main dashboard, list of jobs."
        echo "    *   Trigger a pre-configured sample pipeline job."
        echo "        *   Explain what the job does (e.g., simple build, runs tests)."
        echo "    *   Show the live console output of the running job."
        echo "    *   Show the completed job, status (success/failure), artifacts (if any)."
        echo ""
        echo "3.  **Highlight High Availability (HA) (3 min) - *If applicable/configured***"
        echo "    *   Explain the HA setup (e.g., multiple Jenkins replicas, shared storage)."
        echo "    *   (Optional, if brave & setup allows) Simulate a failure:"
        echo "        *   Docker: \`docker-compose stop jenkins-controller-1\` (assuming multiple controllers)"
        echo "        *   Kubernetes: \`kubectl delete pod <jenkins-pod-name> -n $k8s_namespace_placeholder\`"
        echo "    *   Show Jenkins remaining accessible or recovering quickly."
        echo "    *   Show the new pod/container taking over."
        echo ""
        echo "4.  **Show Monitoring with Grafana (3 min)**"
        echo "    *   Access Grafana via its URL."
        echo "    *   Show the pre-configured Jenkins dashboard."
        echo "    *   Point out key metrics:"
        echo "        *   Number of online executors, build queue length."
        echo "        *   Job success/failure rates, average build duration."
        echo "        *   System metrics (CPU/memory usage of Jenkins instances)."
        echo "    *   Briefly show Prometheus as the data source if time permits."
        echo ""
        echo "5.  **Briefly Touch on Configuration & Deployment (2 min)**"
        echo "    *   Show the \`docker-compose.yml\` or Helm \`values.yaml\` to illustrate ease of configuration."
        echo "    *   Mention the migration scripts (\`assess-migration.sh\`, \`migrate.sh\`)."
        echo ""
        echo "6.  **Q&A (5 min)**"
        echo ""
        echo "##  fallback Options"
        echo ""
        echo "*   **Pre-recorded Video:** Have a screen recording of a successful demo run ready."
        echo "    *   Link: \`[YOUR_PRE_RECORDED_DEMO_VIDEO_LINK_HERE]\`"
        echo "*   **Screenshots:** Prepare key screenshots:"
        echo "    *   Jenkins dashboard, successful job, Grafana dashboard."
        echo "*   **Simpler Local Setup:** If the full HA setup fails, quickly run a single-instance Docker setup locally (if feasible and prepared)."
        echo "*   **Focus on Code/Config:** If live demo fails catastrophically, walk through the codebase, scripts, and configuration files to explain the solution architecture and capabilities."
        echo ""
        echo "---"
        echo "Generated by final-check.sh on $(date)"

    } > "$md_file"

    echo "SUCCESS: DEMO_READY.md created at $md_file"
    echo "INFO: Please review DEMO_READY.md and fill in placeholders like URLs and specific K8s names."
}

package_demo_kit() {
    echo "INFO: Packaging demo kit (demo-kit.zip)..."
    local zip_file="demo-kit.zip"
    local files_to_package=()

    # Add generated files if they exist
    [ -f "deployment_report.txt" ] && files_to_package+=("deployment_report.txt")
    [ -f "DEMO_READY.md" ] && files_to_package+=("DEMO_READY.md")

    # Add script itself
    files_to_package+=("scripts/final-check.sh")

    # Add key project files (check existence before adding)
    [ -f "README.md" ] && files_to_package+=("README.md")
    [ -f ".env.example" ] && files_to_package+=(".env.example")
    [ -f "docker-compose/docker-compose.yml" ] && files_to_package+=("docker-compose/docker-compose.yml")
    [ -d "docker-compose/monitoring" ] && files_to_package+=("docker-compose/monitoring") # Add whole dir
    [ -f "kubernetes/helm/values.yaml" ] && files_to_package+=("kubernetes/helm/values.yaml")
    [ -f "kubernetes/helm/Chart.yaml" ] && files_to_package+=("kubernetes/helm/Chart.yaml")
    [ -d "kubernetes/helm/templates" ] && files_to_package+=("kubernetes/helm/templates") # Add whole dir
    [ -d "scripts" ] && files_to_package+=("scripts") # Add other scripts

    # Create a temporary directory for packaging to keep paths clean in the zip
    local temp_package_dir="demo_kit_temp_staging"
    rm -rf "$temp_package_dir" # Clean up if it exists from a previous failed run
    mkdir -p "$temp_package_dir"

    echo "INFO: Staging files for demo kit..."
    for item in "${files_to_package[@]}"; do
        if [ -e "$item" ]; then
            # Copy items into the staging directory, preserving directory structure for some
            if [[ "$item" == *"/"* && -d "$item" ]]; then # If it's a directory
                mkdir -p "$temp_package_dir/$(dirname "$item")"
                cp -R "$item" "$temp_package_dir/$(dirname "$item")/"
            elif [[ "$item" == *"/"* ]]; then # If it's a file in a subdirectory
                 mkdir -p "$temp_package_dir/$(dirname "$item")"
                 cp "$item" "$temp_package_dir/$item"
            else # If it's a file in the root
                cp "$item" "$temp_package_dir/"
            fi
        else
            echo "WARNING: File or directory '$item' not found, skipping for demo kit."
        fi
    done

    # Add specific files from docs
    if [ -d "docs" ]; then
        mkdir -p "$temp_package_dir/docs"
        [ -f "docs/architecture.md" ] && cp "docs/architecture.md" "$temp_package_dir/docs/"
        [ -f "docs/configuration.md" ] && cp "docs/configuration.md" "$temp_package_dir/docs/"
        [ -f "docs/monitoring.md" ] && cp "docs/monitoring.md" "$temp_package_dir/docs/"
    fi


    if [ ${#files_to_package[@]} -gt 0 ]; then
        echo "INFO: Creating $zip_file..."
        # From inside the temp dir, zip its contents
        (cd "$temp_package_dir" && zip -r "../$zip_file" ./*)
        if [ $? -eq 0 ]; then
            echo "SUCCESS: Demo kit packaged as $zip_file"
        else
            echo "ERROR: Failed to create $zip_file"
        fi
    else
        echo "WARNING: No files were staged for packaging. Demo kit not created."
    fi

    # Clean up temporary directory
    rm -rf "$temp_package_dir"
}

# Main script execution
main() {
    echo "Starting Final Check Script..."
    echo "=============================="

    run_tests
    generate_deployment_report
    create_demo_ready_md
    package_demo_kit

    echo "=============================="
    echo "Final Check Script Completed Successfully!"
    echo "Ensure you review all generated files (deployment_report.txt, DEMO_READY.md) and the demo-kit.zip."
}

# Run the main function
main "$@"
