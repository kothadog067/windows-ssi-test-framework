output "lambda_function_name" {
  value = aws_lambda_function.cost_guard.function_name
}

output "lambda_arn" {
  value = aws_lambda_function.cost_guard.arn
}

output "schedule_rule" {
  value = aws_cloudwatch_event_rule.cost_guard.name
}
