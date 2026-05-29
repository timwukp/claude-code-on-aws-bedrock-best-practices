###############################################################################
# Claude Code Enterprise Baseline — EC2 + SSM + CloudWatch
#
# Replaces deployment-guide.md's manual `sudo cp / chattr / chmod` sequence
# with idempotent IaC. Validate with:
#   terraform fmt && terraform validate
#
# What this provisions:
#   * IAM role with: SSM, CloudWatch Logs, Bedrock Runtime invoke,
#     SecretsManager read for the audit HMAC key.
#   * EC2 instance with a hardened user_data that deploys hooks, managed
#     settings, wrapper, sudoers, drift watcher, logrotate, and CloudWatch
#     agent.
#   * CloudWatch log group with retention + (optional) S3 export for SOX/PCI
#     long retention.
#   * SSM Document so re-running converges existing instances without rebuild.
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI in target region"
  type        = string
}

variable "subnet_id" {
  type = string
}

variable "vpc_security_group_ids" {
  type = list(string)
}

variable "audit_log_retention_days" {
  type    = number
  default = 365
}

variable "kit_repo_url" {
  description = "https/git URL of this kit (cloned at boot)"
  type        = string
}

variable "kit_revision" {
  description = "Pinned git tag or commit SHA — rebuilds when this changes"
  type        = string
}

provider "aws" {
  region = var.region
}

###############################################################################
# CloudWatch log groups
###############################################################################
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/claude-code/audit"
  retention_in_days = var.audit_log_retention_days
}

resource "aws_cloudwatch_log_group" "drift" {
  name              = "/claude-code/drift"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "hooks" {
  name              = "/claude-code/hooks"
  retention_in_days = 30
}

###############################################################################
# IAM
###############################################################################
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "claude-code-baseline"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "perms" {
  statement {
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/anthropic.*"]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [aws_cloudwatch_log_group.audit.arn, "${aws_cloudwatch_log_group.audit.arn}:*", aws_cloudwatch_log_group.drift.arn, "${aws_cloudwatch_log_group.drift.arn}:*", aws_cloudwatch_log_group.hooks.arn, "${aws_cloudwatch_log_group.hooks.arn}:*"]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:*:secret:audit-hmac-key-*"]
  }
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/claude-code/*"]
  }
}

resource "aws_iam_role_policy" "perms" {
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.perms.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "claude-code-baseline"
  role = aws_iam_role.instance.name
}

###############################################################################
# Audit HMAC key in Secrets Manager (rotated independently)
###############################################################################
resource "aws_secretsmanager_secret" "audit_key" {
  name                    = "audit-hmac-key"
  description             = "HMAC key for tamper-evident audit chain"
  recovery_window_in_days = 7
}

###############################################################################
# SSM document — converges hooks/wrapper/managed-settings on every run
###############################################################################
resource "aws_ssm_document" "deploy" {
  name            = "claude-code-deploy"
  document_type   = "Command"
  document_format = "YAML"
  content = templatefile("${path.module}/ssm-deploy.yaml.tpl", {
    repo_url     = var.kit_repo_url
    kit_revision = var.kit_revision
    region       = var.region
    audit_group  = aws_cloudwatch_log_group.audit.name
    drift_group  = aws_cloudwatch_log_group.drift.name
    hooks_group  = aws_cloudwatch_log_group.hooks.name
  })
}

###############################################################################
# EC2 instance
###############################################################################
resource "aws_instance" "workstation" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.vpc_security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name              = "claude-code-baseline"
    KitRevision       = var.kit_revision
    BaselineRebuiltAt = timestamp()
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    region           = var.region
    audit_group      = aws_cloudwatch_log_group.audit.name
    drift_group      = aws_cloudwatch_log_group.drift.name
    hooks_group      = aws_cloudwatch_log_group.hooks.name
    ssm_document     = aws_ssm_document.deploy.name
    audit_secret_arn = aws_secretsmanager_secret.audit_key.arn
  })
}

output "instance_id" { value = aws_instance.workstation.id }
output "audit_log_group" { value = aws_cloudwatch_log_group.audit.name }
output "ssm_document" { value = aws_ssm_document.deploy.name }
