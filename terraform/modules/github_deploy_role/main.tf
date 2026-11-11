# IAM role that GitHub Actions assumes through OIDC to deploy one environment.
# It can run shell commands on exactly one instance through SSM and read the
# result. It cannot touch any other AWS resource.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

variable "name" {
  description = "Role name prefix."
  type        = string
}

variable "github_repository" {
  description = "Repository allowed to assume the role, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the owner/name form, e.g. octocat/care-guide-devops-assessment."
  }
}

variable "github_environment" {
  description = "GitHub Environment (staging, production). Only jobs running in this environment can assume the role, so production approval rules also gate AWS access."
  type        = string
}

variable "instance_arn" {
  description = "ARN of the instance the role may run commands on."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider created by the bootstrap stack."
  type        = string
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_environment}"]
    }
  }
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid     = "RunDeployScriptOnTheInstance"
    actions = ["ssm:SendCommand"]
    resources = [
      var.instance_arn,
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
    ]
  }

  # GetCommandInvocation does not support resource-level permissions.
  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "deploy" {
  name_prefix        = "${var.name}-gh-deploy-"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "deploy" {
  name   = "ssm-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "role_arn" {
  description = "Value for the AWS_ROLE_ARN GitHub environment variable."
  value       = aws_iam_role.deploy.arn
}
