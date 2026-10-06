output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.main.arn
}

output "kms_key_arn" {
  description = "KMS CMK ARN for DynamoDB encryption"
  value       = aws_kms_key.dynamodb.arn
}

output "ssm_table_name_path" {
  description = "SSM path for CDK to resolve table name"
  value       = aws_ssm_parameter.table_name.name
}

output "ssm_table_arn_path" {
  description = "SSM path for CDK to resolve table ARN"
  value       = aws_ssm_parameter.table_arn.name
}

output "sns_alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = aws_sns_topic.alarms.arn
}