variable "name" {
  description = "Name prefix for all resources, e.g. devops-task-staging."
  type        = string
}

variable "environment" {
  description = "Deployment environment label (staging, production)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible; the image is multi-arch, so t4g (Graviton) works too."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (gp3, encrypted)."
  type        = number
  default     = 12
}

variable "app_port" {
  description = "Port the container listens on and the security group opens."
  type        = number
  default     = 8080
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the app port. There is deliberately no default: 0.0.0.0/0 must be a conscious choice."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "Provide at least one CIDR block."
  }
}

variable "vpc_id" {
  description = "VPC to launch into. Null uses the account's default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet to launch into. Null picks a default-for-AZ subnet of the chosen VPC."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for container logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "CloudWatch only accepts specific retention values (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "container_memory_limit" {
  description = "Docker memory limit for the app container."
  type        = string
  default     = "256m"
}

variable "container_cpu_limit" {
  description = "Docker CPU limit (cores) for the app container."
  type        = string
  default     = "0.5"
}

variable "app_env" {
  description = "Non-secret environment variables for the container (written to /etc/app/app.env)."
  type        = map(string)
  default     = {}
}

variable "registry_host" {
  description = "Container registry host."
  type        = string
  default     = "ghcr.io"
}

variable "registry_user" {
  description = "Registry username used for pulls. Only needed for a private image."
  type        = string
  default     = ""
}

variable "registry_token_ssm_parameter" {
  description = "Name of an existing SSM SecureString holding a registry read token. Empty means the image is public. Terraform never sees the token value."
  type        = string
  default     = ""
}

variable "initial_image" {
  description = "Image to start on first boot. Empty leaves the host idle until the first pipeline deploy."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
