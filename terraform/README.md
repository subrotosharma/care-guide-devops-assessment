# Terraform

Requires Terraform >= 1.10 (S3-native state locking) and AWS credentials for anything that touches AWS.

```
bootstrap/                 state bucket + GitHub OIDC provider. Local state, applied once per account.
modules/app_host/          EC2, security group, IAM role + instance profile, CloudWatch log group, cloud-init
modules/github_deploy_role/   OIDC role scoped to one repo, one GitHub Environment, one instance
environments/staging/      calls the modules; state key staging/terraform.tfstate
environments/production/   same modules, larger instance, 90 day log retention, own state key
```

## Initialise, plan, apply, destroy

```bash
# once per account
cd bootstrap
cp terraform.tfvars.example terraform.tfvars      # state_bucket_name must be globally unique
terraform init
terraform apply
# outputs: state bucket name, GitHub OIDC provider ARN

# per environment
cd ../environments/staging
cp backend.hcl.example backend.hcl                # bucket, region
cp terraform.tfvars.example terraform.tfvars      # github_repository, github_oidc_provider_arn, allowed_ingress_cidrs
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
terraform output                                  # instance_id, public_ip, github_deploy_role_arn

# clean up when you are done testing
terraform destroy
```

`terraform.tfvars` and `backend.hcl` are git-ignored; state files must never be committed. After the first `terraform init`, commit the generated `.terraform.lock.hcl` so provider versions are pinned.

Applying creates billable resources (a small EC2 instance, a public IPv4 address, log storage). Staging defaults to `t3.micro`. Destroy when finished.

## Checks that do not need AWS

```bash
terraform fmt -recursive -check .
terraform -chdir=environments/staging init -backend=false && terraform -chdir=environments/staging validate
```

`init -backend=false` skips the S3 backend, so no credentials are needed; it does download the AWS provider.

## Variables worth knowing

| Variable | Notes |
|---|---|
| `allowed_ingress_cidrs` | No default on purpose. Use your own IP/32 for staging. |
| `instance_type` | `t3.micro` staging, `t3.small` production. The image is multi-arch, so `t4g.*` also works. |
| `log_retention_days` | 14 staging, 90 production. |
| `initial_image` | Empty leaves the host idle until the first pipeline deploy. |
| `registry_token_ssm_parameter` | Only for a private image; name of an existing SSM SecureString. Terraform never reads the value. |
| `vpc_id` / `subnet_id` | Null uses the default VPC and a default subnet. |
