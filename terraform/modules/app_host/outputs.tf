output "instance_id" {
  description = "EC2 instance ID. The pipeline targets this with SSM."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IPv4 address of the instance."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "Base URL of the app."
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}"
}

output "security_group_id" {
  value = aws_security_group.app.id
}

output "iam_role_name" {
  value = aws_iam_role.instance.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "instance_arn" {
  description = "Used to scope the CI deploy role's ssm:SendCommand permission."
  value       = aws_instance.app.arn
}
