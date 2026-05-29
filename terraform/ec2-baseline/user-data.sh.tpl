#!/bin/bash
# Claude Code baseline EC2 user_data
# Idempotent: invokes the SSM Document which holds the actual converge logic
set -euxo pipefail
dnf install -y bubblewrap socat jq inotify-tools amazon-cloudwatch-agent

# Trigger the SSM doc that converges the box. Doing the work in SSM (not here)
# means we can re-run on existing instances without rebuilding.
INSTANCE_ID=$(curl -sS http://169.254.169.254/latest/meta-data/instance-id)
aws ssm send-command --region ${region} \
  --document-name "${ssm_document}" \
  --instance-ids "$INSTANCE_ID" \
  --comment "first-boot converge" || true

cat > /etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {"file_path":"/var/log/claude-code/audit.jsonl","log_group_name":"${audit_group}","log_stream_name":"{instance_id}"},
          {"file_path":"/var/log/claude-code/drift.jsonl","log_group_name":"${drift_group}","log_stream_name":"{instance_id}"},
          {"file_path":"/var/log/claude-code/hooks.jsonl","log_group_name":"${hooks_group}","log_stream_name":"{instance_id}"}
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config \
  -m ec2 -s -c file:/etc/amazon-cloudwatch-agent.json
