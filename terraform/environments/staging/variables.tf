variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the app port."
  type        = list(string)
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
  default     = 14
}

variable "container_memory_limit" {
  description = "Docker memory limit for the app container."
  type        = string
  default     = "256m"
}

variable "initial_image" {
  description = "Image started on first boot. Leave empty to let the first pipeline run deploy it."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID. Null uses the default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet ID. Null uses a default subnet."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "owner/name of the repository whose workflow may deploy here."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (bootstrap output github_oidc_provider_arn)."
  type        = string
}
