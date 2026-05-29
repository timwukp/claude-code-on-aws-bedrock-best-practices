###############################################################################
# allowedMcpServers via SSM Parameter Store
#
# Lets IT update the approved MCP server list without re-deploying
# managed-settings.json. The audit-logger reads this on startup.
###############################################################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

variable "region" { default = "us-east-1" }

variable "approved_mcp_servers" {
  type    = list(string)
  default = []
  # e.g. ["github://github.com/anthropics/mcp-github@v1.2.0"]
}

provider "aws" { region = var.region }

resource "aws_ssm_parameter" "allowed_mcp" {
  name  = "/claude-code/allowed-mcp-servers"
  type  = "StringList"
  value = length(var.approved_mcp_servers) == 0 ? "_none_" : join(",", var.approved_mcp_servers)
  tags = {
    Owner = "platform-security"
  }
}

output "parameter_name" { value = aws_ssm_parameter.allowed_mcp.name }
