.PHONY: help
help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: install
install: ## Install dependencies
	@echo "Installing dependencies..."
	@command -v helm >/dev/null 2>&1 || { echo "Please install Helm 3.x"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "Please install kubectl"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Please install Docker"; exit 1; }
	@command -v docker-compose >/dev/null 2>&1 || { echo "Please install Docker Compose"; exit 1; }

.PHONY: lint
lint: ## Run linters
	@echo "Running linters..."
	@shellcheck scripts/*.sh || true
	@yamllint -c .yamllint.yml . || true
	@hadolint docker-compose/Dockerfile* || true

.PHONY: test
test: test-helm test-docker test-scripts ## Run all tests

.PHONY: test-helm
test-helm: ## Test Helm chart
	@echo "Testing Helm chart..."
	@helm lint kubernetes/helm
	@helm template jenkins kubernetes/helm | kubectl apply --dry-run=client -f -

.PHONY: test-docker
test-docker: ## Test Docker Compose
	@echo "Testing Docker Compose..."
	@cd docker-compose && docker-compose config

.PHONY: test-scripts
test-scripts: ## Test shell scripts
	@echo "Testing shell scripts..."
	@bash -n scripts/*.sh

.PHONY: test-security
test-security: ## Run security tests
	@echo "Running security tests..."
	@trivy fs --security-checks vuln,config .
	@checkov -d . --framework kubernetes,helm,dockerfile

.PHONY: deploy-k8s
deploy-k8s: ## Deploy to Kubernetes
	@echo "Deploying to Kubernetes..."
	@helm upgrade --install jenkins ./kubernetes/helm -f ./kubernetes/helm/values-prod.yaml

.PHONY: deploy-docker
deploy-docker: ## Deploy with Docker Compose
	@echo "Deploying with Docker Compose..."
	@cd docker-compose && docker-compose up -d

.PHONY: backup
backup: ## Run backup
	@echo "Running backup..."
	@./scripts/backup.sh

.PHONY: restore
restore: ## Run restore
	@echo "Running restore..."
	@./scripts/restore.sh

.PHONY: monitoring-up
monitoring-up: ## Start monitoring stack
	@echo "Starting monitoring stack..."
	@cd monitoring && docker-compose up -d

.PHONY: monitoring-down
monitoring-down: ## Stop monitoring stack
	@echo "Stopping monitoring stack..."
	@cd monitoring && docker-compose down

.PHONY: clean
clean: ## Clean up resources
	@echo "Cleaning up..."
	@rm -rf tmp/ temp/ *.tmp
	@find . -name "*.log" -type f -delete

.PHONY: dev-setup
dev-setup: ## Setup development environment
	@echo "Setting up development environment..."
	@pip install -r requirements-dev.txt || true
	@npm install --save-dev || true
	@pre-commit install || true
