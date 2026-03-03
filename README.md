# beepee (Bottlerocket) — Terraform experiment (us-east-2)

This scaffold creates an isolated VPC + private subnet EC2 instance running Bottlerocket, with:
- No inbound access (no SSH)
- Egress limited to TCP/443
- NAT for Slack + package/image pulls
- VPC endpoints for Athena/Glue/STS/CloudWatch Logs + S3 (gateway)
- Least-privilege IAM instance role for Athena query execution limited to a WorkGroup (default: beepee)
- An S3 bucket for Athena query results (created by Terraform)
- VPC Flow Logs to CloudWatch

## Manual steps (minimal)
1) Create Slack workspace + app (Socket Mode). Obtain:
   - SLACK_BOT_TOKEN (xoxb-...)
   - SLACK_APP_TOKEN (xapp-...)
2) Put those tokens into `terraform.tfvars` (or your preferred secret injection for the experiment).
3) Provide the beepee container image reference (defaults to a placeholder).
4) (Optional) Add your Athena data S3 bucket/prefix allowlist in `data_access`.

## Run
```bash
cd envs/exp
terraform init
terraform apply
```

After apply, check outputs for:
- instance_id
- results_bucket_name
- vpc_id, subnet_ids

## Notes
- For pristine opsec, rotate Slack tokens after the experiment and consider moving tokens out of tfvars into
  a more secure injection method (e.g., SSM parameter with strict IAM + endpoints) once you're comfortable.
- You can update the Athena WorkGroup name later by changing `athena_workgroup`.
