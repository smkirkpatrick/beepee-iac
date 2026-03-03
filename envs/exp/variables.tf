variable "region" {
  type    = string
  default = "us-east-2"
}

variable "name" {
  type    = string
  default = "beepee-exp"
}

variable "athena_workgroup" {
  type    = string
  default = "beepee"
}

# Container image for beepee (e.g., ghcr.io/yourorg/beepee:tag)
variable "beepee_image" {
  type    = string
  default = "REPLACE_ME/beepee:latest"
}

# Slack tokens for Socket Mode
# For the experiment we allow setting via tfvars; move to safer injection later.
variable "slack_bot_token" {
  type      = string
  sensitive = true
}

variable "slack_app_token" {
  type      = string
  sensitive = true
}

# Optional: extra env vars to pass to the beepee container
variable "beepee_env" {
  type    = map(string)
  default = {}
}

# Allowlisted data locations (prefix-scoped) beepee can read from S3 (Athena underlying data).
# For the first experiment you can leave this empty and run queries like SELECT 1.
# Example:
# data_access = [{ bucket="my-data-bucket", prefix="current/" }]
variable "data_access" {
  type = list(object({
    bucket = string
    prefix = string
  }))
  default = []
}

# Instance sizing
variable "instance_type" {
  type    = string
  default = "t3.large"
}

# Toggle: allow SSM Session Manager break-glass access (recommended; still tightly scoped).
variable "enable_ssm" {
  type    = bool
  default = true
}

# Application-layer egress domain allowlist.
# Note: the SG still allows TCP/443 to 0.0.0.0/0; enforcement is inside the beepee process.
variable "allow_domains" {
  type    = list(string)
  default = []
}

# When true, beepee sends a Slack notification and waits for operator approval
# before connecting to a domain not in allow_domains.
variable "domain_access_requests" {
  type    = bool
  default = true
}
