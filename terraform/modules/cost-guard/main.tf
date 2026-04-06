# =============================================================================
#  cost-guard module
#
#  Deploys a Lambda + EventBridge rule that terminates any EC2 instance
#  tagged SSITest=true that has been running longer than var.max_age_minutes.
#
#  Usage (in your root terraform or standalone):
#    module "cost_guard" {
#      source          = "../../terraform/modules/cost-guard"
#      region          = "us-east-1"
#      max_age_minutes = 120
#    }
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ── Lambda execution role ─────────────────────────────────────────────────────
resource "aws_iam_role" "cost_guard" {
  name = "ssi-cost-guard-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cost_guard" {
  name = "ssi-cost-guard-policy"
  role = aws_iam_role.cost_guard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeAndTerminateInstances"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:TerminateInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.name
          }
        }
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/ssi-cost-guard*"
      }
    ]
  })
}

# ── Lambda function (inline Python) ──────────────────────────────────────────
resource "aws_lambda_function" "cost_guard" {
  function_name = "ssi-cost-guard"
  role          = aws_iam_role.cost_guard.arn
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 60

  environment {
    variables = {
      MAX_AGE_MINUTES = tostring(var.max_age_minutes)
      DRY_RUN         = tostring(var.dry_run)
    }
  }

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  tags = {
    Name    = "ssi-cost-guard"
    SSITest = "true"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/cost_guard_lambda.zip"

  source {
    content  = <<-PYTHON
import boto3
import os
from datetime import datetime, timezone, timedelta

def handler(event, context):
    max_age    = int(os.environ.get("MAX_AGE_MINUTES", "120"))
    dry_run    = os.environ.get("DRY_RUN", "false").lower() == "true"
    ec2        = boto3.client("ec2")
    cutoff     = datetime.now(timezone.utc) - timedelta(minutes=max_age)
    terminated = []
    skipped    = []

    paginator = ec2.get_paginator("describe_instances")
    pages = paginator.paginate(
        Filters=[
            {"Name": "tag:SSITest",            "Values": ["true"]},
            {"Name": "instance-state-name",    "Values": ["running"]},
        ]
    )

    for page in pages:
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                iid        = inst["InstanceId"]
                launch     = inst["LaunchTime"]
                age_min    = (datetime.now(timezone.utc) - launch).total_seconds() / 60
                tags       = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                app_name   = tags.get("App", "unknown")

                if launch < cutoff:
                    print(f"[TERMINATE] {iid} (app={app_name}, age={age_min:.0f}min, dry_run={dry_run})")
                    if not dry_run:
                        ec2.terminate_instances(InstanceIds=[iid])
                    terminated.append({"instance_id": iid, "app": app_name, "age_min": round(age_min)})
                else:
                    print(f"[SKIP]      {iid} (app={app_name}, age={age_min:.0f}min — under limit of {max_age}min)")
                    skipped.append(iid)

    print(f"Summary: terminated={len(terminated)} skipped={len(skipped)} dry_run={dry_run}")
    return {"terminated": terminated, "skipped": skipped, "dry_run": dry_run}
PYTHON
    filename = "index.py"
  }
}

# ── CloudWatch Logs group ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "cost_guard" {
  name              = "/aws/lambda/ssi-cost-guard"
  retention_in_days = 7
}

# ── EventBridge rule — runs every 15 minutes ─────────────────────────────────
resource "aws_cloudwatch_event_rule" "cost_guard" {
  name                = "ssi-cost-guard-schedule"
  description         = "Terminate stale SSI test EC2 instances every 15 min"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "cost_guard" {
  rule      = aws_cloudwatch_event_rule.cost_guard.name
  target_id = "ssi-cost-guard-lambda"
  arn       = aws_lambda_function.cost_guard.arn
}

resource "aws_lambda_permission" "cost_guard" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_guard.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_guard.arn
}
