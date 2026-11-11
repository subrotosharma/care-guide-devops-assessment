output "instance_id" {
  description = "Value for the EC2_INSTANCE_ID GitHub environment variable."
  value       = module.app_host.instance_id
}

output "deploy_role_arn" {
  description = "Value for the AWS_ROLE_ARN GitHub environment variable."
  value       = module.github_deploy_role.role_arn
}

output "app_url" {
  description = "Base URL of the deployed app."
  value       = module.app_host.app_url
}

output "log_group_name" {
  value = module.app_host.log_group_name
}
