.PHONY: install lint test run build image-size up down up-monitoring down-monitoring health shellcheck hadolint validate traffic screenshots k8s-demo

install:
	pip install -r requirements-dev.txt

lint:
	ruff check .

test:
	pytest --cov --cov-report=term-missing

run:
	python -m app

build:
	docker build -t devops-task:local .

up:
	docker compose up -d --build

down:
	docker compose down

up-monitoring:
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build

down-monitoring:
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down

health:
	./scripts/system_health.sh

shellcheck:
	shellcheck scripts/*.sh

hadolint:
	hadolint Dockerfile

image-size:
	@docker image inspect devops-task:local --format '{{.Size}}' | awk '{printf "devops-task:local %.1f MiB\n", $$1/1024/1024}'

validate: lint test shellcheck hadolint
	./tests/test_system_health.sh
	./tests/test_ssm_deploy.sh
	promtool check config monitoring/prometheus/prometheus.yml
	promtool test rules monitoring/prometheus/tests/alerts_test.yml
	terraform fmt -recursive -check terraform
	kustomize build k8s | kubeconform -strict -summary

traffic:
	./scripts/demo_traffic.sh

screenshots:
	python scripts/capture_screenshots.py

k8s-demo:
	./scripts/k8s_demo.sh
