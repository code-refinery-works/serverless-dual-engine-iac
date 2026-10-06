terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, ManagedBy = "terraform" } }
}

# ── KMS CMK ──────────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "dynamodb" {
  description             = "${var.project} DynamoDB CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/${var.project}-dynamodb"
  target_key_id = aws_kms_key.dynamodb.key_id
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "main" {
  name         = "${var.project}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk"; type = "S" }
  attribute { name = "sk"; type = "S" }

  point_in_time_recovery { enabled = true }
  deletion_protection_enabled = true

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  lifecycle { prevent_destroy = true }
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-api"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.dynamodb.arn
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project}"
  retention_in_days = 30
}

# ── SNS Topic for Alarms ──────────────────────────────────────────────────────
resource "aws_sns_topic" "alarms" {
  name = "${var.project}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = [aws_sns_topic.alarms.arn]
  dimensions          = { FunctionName = "${var.project}-api" }
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name          = "${var.project}-ddb-throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alarms.arn]
  dimensions          = { TableName = aws_dynamodb_table.main.name }
}

# ── SSM Parameter Store (CDK連携) ─────────────────────────────────────────────
resource "aws_ssm_parameter" "table_name" {
  name  = "/app/${var.project}/dynamodb/table_name"
  type  = "String"
  value = aws_dynamodb_table.main.name
}

resource "aws_ssm_parameter" "table_arn" {
  name  = "/app/${var.project}/dynamodb/table_arn"
  type  = "String"
  value = aws_dynamodb_table.main.arn
}

resource "aws_ssm_parameter" "kms_arn" {
  name  = "/app/${var.project}/kms/key_arn"
  type  = "String"
  value = aws_kms_key.dynamodb.arn
}