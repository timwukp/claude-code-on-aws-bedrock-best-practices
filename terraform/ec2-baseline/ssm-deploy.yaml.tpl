schemaVersion: "2.2"
description: "Converge Claude Code enterprise baseline on this instance"
parameters:
  KitRevision:
    type: String
    default: "${kit_revision}"
mainSteps:
  - action: aws:runShellScript
    name: cloneKit
    inputs:
      runCommand:
        - set -euxo pipefail
        - test -d /opt/claude-code-kit/.git || git clone "${repo_url}" /opt/claude-code-kit
        - git -C /opt/claude-code-kit fetch --tags --quiet
        - git -C /opt/claude-code-kit checkout "{{KitRevision}}"
  - action: aws:runShellScript
    name: deployHooks
    inputs:
      runCommand:
        - set -euxo pipefail
        - install -d -m 0755 -o root -g root /usr/local/etc/claude-code/hooks
        - install -m 0755 -o root -g root /opt/claude-code-kit/hooks/git-guard.sh /usr/local/etc/claude-code/hooks/
        - install -m 0755 -o root -g root /opt/claude-code-kit/hooks/pii-guard.sh /usr/local/etc/claude-code/hooks/
        - install -m 0755 -o root -g root /opt/claude-code-kit/hooks/audit-logger.sh /usr/local/etc/claude-code/hooks/
        - install -m 0755 -o root -g root /opt/claude-code-kit/hooks/hook-wrapper.sh /usr/local/etc/claude-code/hooks/
        - install -m 0755 -o root -g root /opt/claude-code-kit/hooks/token-budget-guard.sh /usr/local/etc/claude-code/hooks/
  - action: aws:runShellScript
    name: deployManagedSettings
    inputs:
      runCommand:
        - set -euxo pipefail
        - install -d -m 0755 -o root -g root /etc/claude-code
        - python3 -c "import re,json;c=open('/opt/claude-code-kit/docs/managed-settings.jsonc').read();c=re.sub(r'(?<!:)//[^\n]*','',c);c=re.sub(r'/\*.*?\*/','',c,flags=re.S);c=re.sub(r',(\s*[}\]])',r'\1',c);json.dump(json.loads(c),open('/etc/claude-code/managed-settings.json','w'),indent=2)"
        - chown root:root /etc/claude-code/managed-settings.json
        - chmod 0644 /etc/claude-code/managed-settings.json
  - action: aws:runShellScript
    name: deployWrapper
    inputs:
      runCommand:
        - set -euxo pipefail
        - getent group claude-users || groupadd claude-users
        - install -d -m 0755 -o root -g root /opt/claude-code/bin
        - test -x /opt/claude-code/bin/claude || install -m 0750 -o root -g claude-users $(which claude) /opt/claude-code/bin/claude
        - install -m 0755 -o root -g root /opt/claude-code-kit/scripts/wrapper-linux.sh /usr/local/bin/claude
        - install -m 0440 -o root -g root /opt/claude-code-kit/scripts/sudoers-claude-code /etc/sudoers.d/claude-code
        - visudo -cf /etc/sudoers.d/claude-code
  - action: aws:runShellScript
    name: deployAuditAndDrift
    inputs:
      runCommand:
        - set -euxo pipefail
        - install -d -m 0755 -o root -g root /var/log/claude-code /var/lib/claude-code/audit-state
        - touch /var/log/claude-code/audit.jsonl /var/log/claude-code/drift.jsonl /var/log/claude-code/hooks.jsonl
        - chattr +a /var/log/claude-code/audit.jsonl || true
        - install -m 0644 -o root -g root /opt/claude-code-kit/scripts/logrotate-claude-code.conf /etc/logrotate.d/claude-code
        - install -m 0755 -o root -g root /opt/claude-code-kit/scripts/drift-watcher.sh /usr/local/bin/claude-drift-watcher
  - action: aws:runShellScript
    name: deploySystemdUnits
    inputs:
      runCommand:
        - |
          cat > /etc/systemd/system/claude-drift-watcher.service <<EOF
          [Unit]
          Description=Claude Code drift watcher
          After=network-online.target
          [Service]
          ExecStart=/usr/local/bin/claude-drift-watcher
          Restart=always
          User=root
          Environment=CLAUDE_DRIFT_LOG=/var/log/claude-code/drift.jsonl
          [Install]
          WantedBy=multi-user.target
          EOF
        - systemctl daemon-reload
        - systemctl enable --now claude-drift-watcher
  - action: aws:runShellScript
    name: lockMcpConfig
    inputs:
      runCommand:
        - set -euxo pipefail
        - touch ~/.claude.json || true
        - chattr +i ~/.claude.json 2>/dev/null || true
