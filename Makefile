# SSI Test Framework — convenience targets
# Requires: AWS_REGION, DD_API_KEY, DD_SITE env vars

.PHONY: all test-all test-app plan destroy-all

## Run all app tests end-to-end
all: test-all

test-all:
	bash run_all.sh

## Test a single app: make test-app APP=dd-dog-runner
test-app:
	APP_FILTER=$(APP) bash run_all.sh

## Dry-run terraform plan for all apps
plan:
	@for app in apps/*/terraform; do \
		echo "=== Plan: $$app ==="; \
		cd $$app && terraform init -reconfigure -backend=false -input=false 2>/dev/null && \
		terraform plan -var "dd_api_key=DRY_RUN" -var "dd_site=datadoghq.com" -input=false; \
		cd ../../..; \
	done

## Emergency: destroy all SSI test EC2s (by tag)
destroy-all:
	@echo "Finding and terminating all instances tagged SSITest=true in $(AWS_REGION)..."
	aws ec2 describe-instances \
		--region $(AWS_REGION) \
		--filters "Name=tag:SSITest,Values=true" "Name=instance-state-name,Values=running,stopped" \
		--query "Reservations[].Instances[].InstanceId" \
		--output text | xargs -r aws ec2 terminate-instances --region $(AWS_REGION) --instance-ids
