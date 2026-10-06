variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project name prefix (used for all resource names)"
  type        = string
  default     = "serverless-api"
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (empty = skip subscription)"
  type        = string
  default     = ""
}