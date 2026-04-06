# SSI Test Framework — convenience targets
# Requires: AWS_REGION, DD_API_KEY, DD_SITE env vars

.PHONY: all test-all test-app plan new-app bootstrap cost-guard destroy-all

## Run all app tests end-to-end (parallel)
all: test-all

test-all:
	bash run_all.sh

## Test a single app: make test-app APP=dd-dog-runner
test-app:
	APP_FILTER=$(APP) bash run_all.sh

## Scaffold a new test app: make new-app NAME=dd-dotnet-wcf
new-app:
	bash scripts/new_app.sh $(NAME)

## One-time bootstrap: create S3 state bucket + DynamoDB lock table
bootstrap:
	cd terraform/bootstrap && terraform init && terraform apply \
		-var="state_bucket_name=$(TF_STATE_BUCKET)" \
		-var="region=$(AWS_REGION)"

## Deploy cost guard Lambda (terminates stale SSI test instances)
cost-guard:
	cd terraform/modules/cost-guard && terraform init && terraform apply \
		-var="max_age_minutes=120"

## Dry-run terraform plan for all apps
plan:
	@for app in apps/*/terraform; do \
		echo "=== Plan: $$app ==="; \
		terraform -chdir=$$app init -reconfigure -backend=false -input=false 2>/dev/null && \
		terraform -chdir=$$app plan -var "dd_api_key=DRY_RUN" -var "dd_site=datadoghq.com" -input=false; \
	done

## Emergency: terminate all running SSITest=true instances by tag
destroy-all:
	@echo "Terminating all instances tagged SSITest=true in $(AWS_REGION)..."
	aws ec2 describe-instances \
		--region $(AWS_REGION) \
		--filters "Name=tag:SSITest,Values=true" "Name=instance-state-name,Values=running,stopped" \
		--query "Reservations[].Instances[].InstanceId" \
		--output text | xargs -r aws ec2 terminate-instances --region $(AWS_REGION) --instance-ids
