data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Random suffix for globally-unique S3 bucket name ---
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  results_bucket_name = lower("${var.name}-athena-results-${random_id.suffix.hex}")
  tags = {
    Project = var.name
  }
}

# ------------------------
# Networking: dedicated VPC
# ------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"
  tags                    = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "${var.region}a"
  tags                    = merge(local.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route" "public_inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = merge(local.tags, { Name = "${var.name}-nat" })
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-rt-private" })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ------------------------
# Security group: no ingress, egress TCP/443 only
# ------------------------
resource "aws_security_group" "beepee" {
  name        = "${var.name}-sg"
  description = "No ingress, egress 443 only"
  vpc_id      = aws_vpc.this.id

  ingress = []

  egress {
    description = "HTTPS only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-sg" })
}

# ------------------------
# S3: Athena query results bucket
# ------------------------
resource "aws_s3_bucket" "results" {
  bucket = local.results_bucket_name
  tags   = merge(local.tags, { Name = local.results_bucket_name })
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ------------------------
# Logging: CloudWatch log group + VPC flow logs
# ------------------------
resource "aws_cloudwatch_log_group" "beepee" {
  name              = "/beepee/${var.name}"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_iam_role" "vpc_flowlogs" {
  name               = "${var.name}-vpc-flowlogs-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_flowlogs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "vpc_flowlogs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["vpc-flow-logs.amazonaws.com"] }
  }
}

resource "aws_iam_role_policy" "vpc_flowlogs" {
  role   = aws_iam_role.vpc_flowlogs.id
  policy = data.aws_iam_policy_document.vpc_flowlogs_policy.json
}

data "aws_iam_policy_document" "vpc_flowlogs_policy" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["${aws_cloudwatch_log_group.beepee.arn}:*"]
  }
}

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_group_name       = aws_cloudwatch_log_group.beepee.name
  iam_role_arn         = aws_iam_role.vpc_flowlogs.arn
  tags                 = local.tags
}

# ------------------------
# VPC endpoints (AWS APIs stay private)
# ------------------------
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpce-sg"
  description = "Allow HTTPS from private subnet to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from private subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private.cidr_block]
  }

  egress = []
  tags   = merge(local.tags, { Name = "${var.name}-vpce-sg" })
}

# S3 gateway endpoint
data "aws_iam_policy_document" "s3_vpce_policy" {
  statement {
    sid     = "AllowResultsBucketAndApprovedData"
    effect  = "Allow"
    actions = ["s3:*"]
    resources = concat(
      [
        "arn:aws:s3:::${aws_s3_bucket.results.bucket}",
        "arn:aws:s3:::${aws_s3_bucket.results.bucket}/*",
      ],
      flatten([
        for d in var.data_access : [
          "arn:aws:s3:::${d.bucket}",
          "arn:aws:s3:::${d.bucket}/${d.prefix}*"
        ]
      ])
    )
    principals { type = "*", identifiers = ["*"] }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = data.aws_iam_policy_document.s3_vpce_policy.json
  tags              = merge(local.tags, { Name = "${var.name}-vpce-s3" })
}

# Interface endpoints we use
locals {
  interface_endpoints = toset([
    "athena",
    "glue",
    "logs",
    "sts",
  ])
  ssm_endpoints = toset([
    "ssm",
    "ec2messages",
    "ssmmessages",
  ])
  endpoints_to_create = var.enable_ssm ? setunion(local.interface_endpoints, local.ssm_endpoints) : local.interface_endpoints
}

resource "aws_vpc_endpoint" "iface" {
  for_each            = local.endpoints_to_create
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.tags, { Name = "${var.name}-vpce-${each.key}" })
}

# ------------------------
# IAM: instance role, least privilege for Athena + S3 + Glue + Logs (+ optional SSM)
# ------------------------
resource "aws_iam_role" "beepee" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["ec2.amazonaws.com"] }
  }
}

data "aws_iam_policy_document" "beepee_policy" {

  # Athena query actions constrained to a single workgroup
  statement {
    sid     = "AthenaQueryInWorkgroupOnly"
    effect  = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
      "athena:ListDataCatalogs",
      "athena:ListDatabases",
      "athena:ListTableMetadata"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "athena:WorkGroup"
      values   = [var.athena_workgroup]
    }
  }

  # Glue catalog read-only (commonly required for Athena)
  statement {
    sid     = "GlueCatalogReadOnly"
    effect  = "Allow"
    actions = [
      "glue:GetDatabase","glue:GetDatabases",
      "glue:GetTable","glue:GetTables",
      "glue:GetPartition","glue:GetPartitions",
      "glue:GetDataCatalogEncryptionSettings"
    ]
    resources = ["*"]
  }

  # S3 results bucket: RW under all keys (you can tighten to a prefix later)
  statement {
    sid     = "S3AthenaResultsRW"
    effect  = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload"
    ]
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.results.bucket}",
      "arn:aws:s3:::${aws_s3_bucket.results.bucket}/*"
    ]
  }

  # S3 data read-only allowlist (prefix scoped)
  dynamic "statement" {
    for_each = length(var.data_access) > 0 ? [1] : []
    content {
      sid     = "S3DataReadOnly"
      effect  = "Allow"
      actions = ["s3:GetBucketLocation","s3:ListBucket","s3:GetObject"]
      resources = flatten([
        for d in var.data_access : [
          "arn:aws:s3:::${d.bucket}",
          "arn:aws:s3:::${d.bucket}/${d.prefix}*"
        ]
      ])
    }
  }

  # CloudWatch Logs: write to a dedicated log group
  statement {
    sid     = "CWLogsWrite"
    effect  = "Allow"
    actions = ["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.beepee.arn}:*"]
  }

  # Optional: SSM break-glass
  dynamic "statement" {
    for_each = var.enable_ssm ? [1] : []
    content {
      sid     = "SSMCore"
      effect  = "Allow"
      actions = [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel","ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel","ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage","ec2messages:DeleteMessage",
        "ec2messages:FailMessage","ec2messages:GetEndpoint",
        "ec2messages:GetMessages","ec2messages:SendReply"
      ]
      resources = ["*"]
    }
  }

  # Explicit Deny guardrails: prevent AWS pivot/escalation
  statement {
    sid     = "DenyPivotAndEscalation"
    effect  = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "kms:*",
      "secretsmanager:*",
      "sts:AssumeRole",
      "ec2:*",
      "lambda:*",
      "eks:*",
      "ecs:*"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "beepee_inline" {
  role   = aws_iam_role.beepee.id
  policy = data.aws_iam_policy_document.beepee_policy.json
}

resource "aws_iam_instance_profile" "beepee" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.beepee.name
}

# ------------------------
# Bottlerocket AMI lookup (aws-k8s/ecs variants vary; we use the official SSM param)
# ------------------------
# Bottlerocket publishes AMI IDs via SSM Parameter Store. We pick the ECS variant for broad compatibility.
# If you prefer the EKS variant later, we can swap the parameter path.
data "aws_ssm_parameter" "bottlerocket_ami" {
  name = "/aws/service/bottlerocket/aws-ecs-1/x86_64/latest/image_id"
}

# ------------------------
# Bottlerocket user data (TOML)
# Uses a bootstrap container to run OpenClaw (Socket Mode) with strict-ish defaults.
# ------------------------
locals {
  beepee_env_json = jsonencode(var.beepee_env)

  bottlerocket_user_data = <<-TOML
  [settings]
  motd = "beepee ${var.name} - Bottlerocket"

  [settings.kernel]
  lockdown = "integrity"

  [settings.host-containers.admin]
  enabled = ${var.enable_ssm ? "true" : "false"}

  [settings.bootstrap-containers.beepee]
  source = "${var.beepee_image}"
  mode = "always"
  essential = true

  [settings.bootstrap-containers.beepee.env]
  SLACK_BOT_TOKEN = "${var.slack_bot_token}"
  SLACK_APP_TOKEN = "${var.slack_app_token}"
  ATHENA_WORKGROUP = "${var.athena_workgroup}"
  ATHENA_OUTPUT_S3 = "s3://${aws_s3_bucket.results.bucket}/"
  BEEPEE_EXTRA_ENV_JSON = '${local.beepee_env_json}'
  BEEPEE_ALLOW_DOMAINS = '${jsonencode(var.allow_domains)}'
  BEEPEE_REQUEST_DOMAIN_ACCESS = "${var.domain_access_requests ? "true" : "false"}"

  # If your beepee needs a specific command/args, uncomment and set:
  # [settings.bootstrap-containers.beepee.command]
  # command = ["your", "cmd"]
  TOML
}

resource "aws_instance" "beepee" {
  ami                    = data.aws_ssm_parameter.bottlerocket_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.beepee.id]
  iam_instance_profile   = aws_iam_instance_profile.beepee.name

  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = local.bottlerocket_user_data

  tags = merge(local.tags, { Name = "${var.name}-beepee" })
}
