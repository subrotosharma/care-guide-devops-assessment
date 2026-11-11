data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Amazon Linux 2023 resolved through the public SSM parameter, so a rebuild
# picks up the current patched AMI without hardcoding an ID per region.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.cpu_arch}"
}

locals {
  cpu_arch  = startswith(var.instance_type, "t4g") || startswith(var.instance_type, "c7g") || startswith(var.instance_type, "m7g") ? "arm64" : "x86_64"
  subnet_id = coalesce(var.subnet_id, try(data.aws_subnets.selected[0].ids[0], null))
  log_group = "/${var.name}/app"

  tags = merge(var.tags, {
    Project     = "care-guide-devops-assessment"
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  app_env = merge({
    APP_PORT = tostring(var.app_port)
    APP_ENV  = var.environment
  }, var.app_env)
}

# ---------------------------------------------------------------- networking
resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "App port only. No SSH: shell access goes through SSM Session Manager."
  vpc_id      = data.aws_vpc.selected.id

  tags = { Name = "${var.name}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "App traffic"
  cidr_ipv4         = each.value
  from_port         = var.app_port
  to_port           = var.app_port
  ip_protocol       = "tcp"
}

# Outbound is needed to pull the image, reach SSM and ship logs to CloudWatch.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Image pulls, SSM, CloudWatch, OS updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------------- logging
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ----------------------------------------------------------------------- IAM
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name_prefix        = "${var.name}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

# Lets the SSM agent register the instance so the pipeline can run commands on
# it and operators can open a shell, replacing SSH and its key management.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # Docker's awslogs driver writes to this one group and nowhere else. It also
  # creates streams but not groups, since Terraform owns the group.
  statement {
    sid       = "WriteAppLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  dynamic "statement" {
    for_each = var.registry_token_ssm_parameter == "" ? [] : [1]
    content {
      sid     = "ReadRegistryToken"
      actions = ["ssm:GetParameter"]
      resources = [
        "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(var.registry_token_ssm_parameter, "/")}"
      ]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "app-runtime"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------- EC2
resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # Default VPC subnets hand out public IPs; this just makes it explicit.
  associate_public_ip_address = true

  monitoring = false # detailed (1-minute) monitoring is billed

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # 2 so containers can reach IMDS if they ever need to
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data_base64 = base64encode(templatefile("${path.module}/templates/cloud-config.yaml.tftpl", {
    deploy_script_b64 = filebase64("${path.module}/files/deploy-app.sh")
    app_env           = local.app_env
    app_port          = var.app_port
    region            = data.aws_region.current.name
    log_group         = aws_cloudwatch_log_group.app.name
    log_stream_prefix = var.name
    memory_limit      = var.container_memory_limit
    cpu_limit         = var.container_cpu_limit
    registry_host     = var.registry_host
    registry_user     = var.registry_user
    registry_token    = var.registry_token_ssm_parameter
    initial_image     = var.initial_image
  }))

  # The AMI parameter always points at the newest image. Without this, every
  # apply after a new AL2023 release would replace the instance.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = var.name }

  depends_on = [aws_iam_role_policy.instance]
}
