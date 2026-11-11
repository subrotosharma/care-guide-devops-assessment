terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Bucket and region are supplied at init time (see backend.hcl.example) because
  # the bucket name is unique per account. use_lockfile enables S3-native state
  # locking, so no DynamoDB table is needed.
  backend "s3" {
    key          = "production/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "care-guide-devops-assessment"
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

module "app_host" {
  source = "../../modules/app_host"

  name                   = "devops-task-production"
  environment            = "production"
  instance_type          = var.instance_type
  allowed_ingress_cidrs  = var.allowed_ingress_cidrs
  log_retention_days     = var.log_retention_days
  container_memory_limit = var.container_memory_limit
  initial_image          = var.initial_image
  vpc_id                 = var.vpc_id
  subnet_id              = var.subnet_id
}

module "github_deploy_role" {
  source = "../../modules/github_deploy_role"

  name               = "devops-task-production"
  github_repository  = var.github_repository
  github_environment = "production"
  instance_arn       = module.app_host.instance_arn
  oidc_provider_arn  = var.github_oidc_provider_arn
}
