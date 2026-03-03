# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **beepee-iac** — Terraform infrastructure for deploying **beepee**, a Slack bot (Socket Mode) that executes Athena SQL queries. The stack runs on a hardened Bottlerocket EC2 instance in a private subnet with minimal attack surface.

## Commands

All Terraform commands run from the environment directory:

```bash
cd envs/exp

terraform init          # First-time setup or after provider changes
terraform plan          # Preview changes
terraform apply         # Deploy infrastructure
terraform destroy       # Tear down all resources
```

Before `terraform apply`, copy and populate secrets:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set slack_bot_token, slack_app_token, beepee_image
```

## Docker image

The beepee image extends `ghcr.io/openclaw/openclaw:latest` with a hardened `openclaw.json` baked in. Source is in `docker/`.

**First-time setup** (ECR must exist before pushing):

```bash
# Step 1: create ECR (can apply before the image exists — Bottlerocket only pulls on boot)
cd envs/exp && terraform apply

# Step 2: authenticate Docker to ECR
ECR_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin "$ECR_URL"

# Step 3: build and push (--platform flag required on Apple Silicon)
docker buildx build --platform linux/amd64 \
  -t "$ECR_URL:latest" \
  --push \
  ../../docker

# Step 4: set beepee_image in terraform.tfvars, then replace the instance
terraform apply -replace=aws_instance.beepee
```

**Updating the image** (tag change or config update):

```bash
docker buildx build --platform linux/amd64 -t "$ECR_URL:latest" --push ../../docker
terraform apply -replace=aws_instance.beepee
```

**`docker/openclaw.json`** bakes in: tool deny list (`exec`, `fs.write`, `fs.delete`, `config.patch`), workspace-only filesystem, and sensitive log redaction. The `config.patch` deny is the countermeasure against agents lowering their own guardrails. Add `BEEPEE_GATEWAY_TOKEN` to the instance env vars if you want a non-empty gateway auth token.

## Architecture

**Single environment:** `envs/exp/` — there is currently only one environment (experiment).

**Networking design (security-first):**
- Dedicated VPC (10.42.0.0/16) with public + private subnets
- EC2 instance lives in the **private subnet only** — no public IP, no inbound ingress
- Egress limited to **TCP/443 only** via NAT gateway (for Slack Socket Mode)
- VPC interface endpoints keep AWS API calls (Athena, Glue, STS, CloudWatch Logs) off the public internet; S3 uses a gateway endpoint
- SSM Session Manager is the only break-glass access path (`enable_ssm = true`)

**Compute:**
- Bottlerocket AMI (ECS variant) looked up dynamically from SSM Parameter Store
- beepee runs as a bootstrap container; Slack tokens and config injected via TOML user data
- IMDSv2 enforced with hop limit = 1

**IAM (least privilege with explicit deny guardrails):**
- Instance role allows: Athena queries scoped to one workgroup, Glue catalog reads, S3 RW on results bucket, S3 read-only on allowlisted data prefixes, CloudWatch Logs writes, optional SSM
- Explicit `Deny` covers: `iam:*`, `sts:AssumeRole`, `ec2:*`, `lambda:*`, `kms:*`, `secretsmanager:*`, `organizations:*`, `eks:*`, `ecs:*` — preventing pivot/escalation

**Key variables to configure:**
| Variable | Purpose |
|---|---|
| `beepee_image` | ECR image URI — set after first `terraform apply` + push |
| `slack_bot_token` | Slack bot token (`xoxb-...`) — marked sensitive |
| `slack_app_token` | Slack app-level token (`xapp-...`) — marked sensitive |
| `data_access` | List of `{bucket, prefix}` pairs for Athena data S3 allowlist |
| `athena_workgroup` | Workgroup name (default: `beepee`) |
| `enable_ssm` | Toggle SSM break-glass + associated endpoints/IAM |

**Outputs after apply:** `instance_id`, `results_bucket_name`, `ecr_repository_url`, `vpc_id`, `private_subnet_id`, `log_group_name`, `region`

## Security Constraints to Preserve

When modifying IAM or networking resources, preserve these invariants:
1. The `DenyPivotAndEscalation` deny statement in the instance role policy must remain in place
2. The EC2 security group must have no ingress rules
3. IMDSv2 must stay required (`http_tokens = "required"`)
4. Slack tokens must remain `sensitive = true` in variable definitions
5. The S3 VPC endpoint policy restricts S3 access to the results bucket + allowlisted data — do not widen to `*`
