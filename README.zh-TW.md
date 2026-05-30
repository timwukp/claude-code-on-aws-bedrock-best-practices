# 安全部署 Claude Code on AWS Bedrock — 企業部署套件

> 經過實機測試的安全配置、Hook、營運文件,
> 用於在受監管的企業環境(銀行、醫療、政府)中,
> 在 [Amazon Bedrock](https://aws.amazon.com/bedrock/) 上部署 [Claude Code](https://code.claude.com)。

[English Version](README.md)

---

## 目錄

- [為什麼需要這個套件](#為什麼需要這個套件)
- [深度防禦架構](#深度防禦架構)
- [設定階層](#設定階層)
- [快速開始 (5 分鐘)](#快速開始-linuxmacos5-分鐘)
- [被攔截的內容](#被攔截的內容)
- [平台差異](#平台差異)
- [文件索引](#文件索引)
- [專案結構](#專案結構)
- [測試環境](#測試環境)
- [授權與貢獻](#授權與貢獻)

---

## 為什麼需要這個套件

Claude Code 功能強大,但預設情況下可能會:
- 讀取你的 `.env`、AWS 憑證、SSH 金鑰
- 推送程式碼到任意 git remote
- 執行 `curl` / `wget` 把資料外洩到外部伺服器
- 執行破壞性指令 (`rm -rf`、`git reset --hard`)
- 被誘導繞過權限控制

在受監管的環境裡,這是不可接受的。
本套件提供**經過測試的控制機制**,在不影響開發者生產力的前提下,鎖定 Claude Code。

## 深度防禦架構

七層強制執行機制,全部在實際 AWS 環境測試過:

| 層級 | 機制 | 攔下什麼 | 詳細文件 |
|---|---|---|---|
| 1 | **權限拒絕規則** | 單 token 危險指令 | [`docs/security-rationale.md`](docs/security-rationale.md) |
| 2 | **`pii-guard.sh`** Hook | Prompt 與工具輸入中的敏感資料 | [`docs/pii-guard.md`](docs/pii-guard.md) |
| 3 | **`git-guard.sh`** Hook | 未授權 git push、分支違規、force-push | [hook 原始碼](hooks/git-guard.sh) |
| 4 | **`audit-logger.sh`** Hook | 規避稽核 (偵測型控制) | [hook 原始碼](hooks/audit-logger.sh) |
| 5 | **`token-budget-guard.sh`** Hook | Token 費用爆炸、失控的 session | [hook 原始碼](hooks/token-budget-guard.sh) |
| 6 | **Wrapper Script + 檔案系統 ACL** | `--dangerously-skip-permissions`、`claude mcp add` | [wrapper-linux.sh](scripts/wrapper-linux.sh) |
| 7 | **Bedrock Guardrails**（伺服器端） | 有害內容、輸出中的 PII、不雅用語 | [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) |

加上 **作業系統沙盒** (bubblewrap) 與 **網路隔離** (VPC Endpoint)。
完整的 STRIDE 攻擊樹分析請參考 [`docs/threat-model.md`](docs/threat-model.md)。

## 設定階層

Claude Code 從四個層級合併設定。較高層級覆蓋較低層級,managed 階層的拒絕規則無法被低層級移除:

| 層級 | 路徑 | 擁有者 | 已測試 |
|---|---|---|---|
| 1. 企業 Managed (最高) | `/etc/claude-code/managed-settings.json` (Linux)<br>`C:\Program Files\ClaudeCode\managed-settings.json` (Win) | root / Administrators | ✅ |
| 2. User Settings | `~/.claude/settings.json` | 開發者 | ✅ |
| 3. Project Settings (可分享) | `.claude/settings.json` (在 repo 中) | 團隊 | (與 L2 同格式) |
| 4. Local Project Overrides | `.claude/settings.local.json` (gitignored) | 開發者 | (同格式) |

**已驗證的 managed-only 強制執行:**
- `allowManagedPermissionRulesOnly: true` — user 階層的 deny rules 被忽略 ✅
- `allowManagedHooksOnly: true` — 僅 managed hooks 觸發 ✅
- `allowManagedMcpServersOnly: true` — 執行時過濾 MCP servers ✅

> ⚠ **陷阱**: user settings 的 env vars 確實會覆蓋 managed env vars (這是設計如此,
> 但殘留的 user 階層 `CLAUDE_AUDIT_LOG` 可能靜默破壞稽核日誌)。
> 部署前的檢查指令見 [`docs/deployment-guide.md`](docs/deployment-guide.md#step-8)。

本套件提供 Level 1 與 Level 2 的設定:
- [`docs/managed-settings.jsonc`](docs/managed-settings.jsonc) → Level 1
- [`docs/settings-linux-macos.jsonc`](docs/settings-linux-macos.jsonc) / [`docs/settings-windows.jsonc`](docs/settings-windows.jsonc) → Level 2

## 快速開始 (Linux/macOS,5 分鐘)

```bash
# 0. 安裝 Claude Code
# 建議方式:
curl -fsSL https://claude.ai/install.sh | bash          # macOS / Linux
# 其他方式:
# brew install --cask claude-code                       # Homebrew
# irm https://claude.ai/install.ps1 | iex              # Windows (PowerShell)
# winget install Anthropic.ClaudeCode                   # Windows (winget)
# npm install -g @anthropic-ai/claude-code              # 已棄用的備用方式

# 1. 安裝相依套件
sudo dnf install -y bubblewrap socat jq    # 或 apt install ...

# 2. 部署 hooks (root 擁有,可執行)
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/git-guard.sh hooks/pii-guard.sh hooks/audit-logger.sh \
        /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/*.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# 3. 部署 managed settings (root 擁有)
sudo mkdir -p /etc/claude-code
# 移除 JSONC 註解後部署:
python3 -c "import re,json;c=open('docs/managed-settings.jsonc').read();c=re.sub(r'(?<!:)//[^\n]*','',c);c=re.sub(r'/\*.*?\*/','',c,flags=re.S);c=re.sub(r',(\s*[}\]])',r'\1',c);json.dump(json.loads(c),open('/tmp/m.json','w'),indent=2)"
sudo mv /tmp/m.json /etc/claude-code/managed-settings.json
sudo chown root:root /etc/claude-code/managed-settings.json

# 4. 部署 wrapper (取代使用者面對的 claude)
sudo mkdir -p /opt/claude-code/bin
sudo mv $(which claude) /opt/claude-code/bin/claude
sudo cp scripts/wrapper-linux.sh /usr/local/bin/claude
sudo chown root:root /usr/local/bin/claude
sudo chmod 0755 /usr/local/bin/claude

# 5. 鎖定 MCP 設定 (阻止 `claude mcp add`)
touch ~/.claude.json
sudo chattr +i ~/.claude.json

# 6. 設定稽核日誌 + 旋轉
sudo mkdir -p /var/log/claude-code
sudo touch /var/log/claude-code/audit.jsonl
sudo chmod 0666 /var/log/claude-code/audit.jsonl
sudo chattr +a /var/log/claude-code/audit.jsonl
sudo cp scripts/logrotate-claude-code.conf /etc/logrotate.d/claude-code

# 7. 驗證
claude -p "say PONG"                                # → PONG (正常)
claude -p "My card is 4111-1111-1111-1111"          # → 被擋 (PII guard)
claude -p "hi" --dangerously-skip-permissions       # → Refused (wrapper)
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied
```

完整部署 (含 user settings、漂移偵測、黃金映像) 請見
[`docs/deployment-guide.md`](docs/deployment-guide.md)。

## 被攔截的內容

### PII 與機密 (永遠不會送到模型)

| 資料類型 | 範例 | 結果 |
|---|---|---|
| 信用卡 | `4111-1111-1111-1111` | ✅ 攔截 |
| AWS keys | `AKIAIOSFODNN7EXAMPLE` | ✅ 攔截 |
| 私鑰 | `-----BEGIN RSA PRIVATE KEY-----` | ✅ 攔截 |
| JWT tokens | `eyJhbG...` (3 段 base64url) | ✅ 攔截 |
| 密碼 | `password=SuperSecret123!` | ✅ 攔截 |
| 新加坡 NRIC | `S1234567D` | ✅ 攔截 |
| 電話、護照、Email | 各種 | ✅ 攔截 |
| GitHub/GitLab/Slack tokens | `ghp_...`, `xoxb-...` | ✅ 攔截 |
| DB 連線字串 | `postgres://user:pass@host/db` | ✅ 攔截 |
| 一般 prompt | `"寫一個排序函數"` | ✅ 通過 |

完整清單與客製化: [`docs/pii-guard.md`](docs/pii-guard.md)。

### 危險指令 (被規則或 hook 拒絕)

| 指令 | Linux | Windows |
|---|---|---|
| `rm -rf *` / `Remove-Item -Recurse` | ✅ 拒絕 | ✅ 拒絕 |
| `git push` 到未授權 remote | ✅ Hook 攔截 | ✅ 拒絕 |
| `git push` 到 feature 分支 (允許的 remote) | ✅ **允許** | ✅ **允許** |
| `git push` 到受保護分支 (main/master) | ✅ Hook 攔截 | ✅ 拒絕 |
| `git push --force` | ✅ Hook 攔截 | ✅ 拒絕 |
| `git remote add` (未授權網域) | ✅ Hook 攔截 | ✅ 拒絕 |
| `git remote add` (允許的網域) | ✅ **允許** | ✅ **允許** |
| `git reset --hard` / `git clean -fd` | ✅ Hook 攔截 | ✅ 拒絕 |
| `curl` / `wget` / `Invoke-WebRequest` | ✅ 拒絕 | ✅ 拒絕 |
| `sudo` / `Set-ExecutionPolicy` | ✅ 拒絕 | ✅ 拒絕 |
| `aws iam` / `aws sts` / `aws secretsmanager` | ✅ 拒絕 | ✅ 拒絕 |
| 讀取 `.env` / `.aws/credentials` / `.ssh/` | ✅ 拒絕 | ☑️ 改用 sandbox.denyRead |
| 寫入 `C:\Windows\` | N/A | ✅ 拒絕 |

### 繞過嘗試 (被 wrapper 阻擋)

| 繞過方式 | 結果 |
|---|---|
| `--dangerously-skip-permissions` | ✅ Wrapper 拒絕 |
| `--allow-dangerously-skip-permissions` | ✅ 拒絕 |
| `--permission-mode auto` / `bypassPermissions` | ✅ 拒絕 |
| `--bare` (跳過 hooks) | ✅ 拒絕 |
| `claude mcp add --scope user` | ✅ EPERM (chattr +i) |

## 平台差異

| 行為 | Linux/macOS (Bash) | Windows (PowerShell) |
|---|---|---|
| `<tool>(git push *)` deny | ☑️ 改用 `:*` 語法 (Bash matcher bug) | ✅ 直接可用 |
| `<tool>(git remote add *)` deny | ☑️ 改用 git-guard.sh hook | ✅ 直接可用 |
| `Read(**/.env)` deny | ✅ 可用 | ☑️ 改用 sandbox.denyRead |
| OS sandbox (bubblewrap) | ✅ 支援 | ❌ 原生不支援 |
| PII guard 範圍 | ✅ UserPromptSubmit + PreToolUse | ☑️ 僅 PreToolUse (UserPromptSubmit 在 Windows `--print` 模式不會觸發;以 Bedrock Guardrails 補 prompt 階段 PII) |
| `chattr +i` 鎖 MCP | ✅ ext4/xfs | ☑️ 改用 `icacls` (Win) 或 **`sudo chflags schg`** (macOS — 注意 `chflags uchg` 用戶可自解,須用 `schg` + 非 root 用戶。見 known-issues Issue 11) |

完整平台相容性: [`docs/known-issues.md`](docs/known-issues.md)。

## 文件索引

文件依受眾與用途分組:

### 給開發者 / IT 維運 (部署與執行)
- [`docs/deployment-guide.md`](docs/deployment-guide.md) — 黃金映像逐步檢查清單
- [`docs/operations-runbook.md`](docs/operations-runbook.md) — Onboarding、offboarding、緊急停用、憑證輪替
- [`docs/known-issues.md`](docs/known-issues.md) — Matcher bug、平台特性、已驗證 workaround
- [`docs/test-results.md`](docs/test-results.md) — 完整測試證據 (Linux + Windows e2e)

### 給安全團隊 (審查、監控、回應)
- [`docs/threat-model.md`](docs/threat-model.md) — STRIDE 分析與攻擊樹
- [`docs/security-rationale.md`](docs/security-rationale.md) — 威脅 → 控制 對應表
- [`docs/pii-guard.md`](docs/pii-guard.md) — PII guard hook 細節與客製化
- [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) — AWS Bedrock Guardrails 整合指南（7 層防護策略、配置方式、已知限制）
- [`docs/incident-response.md`](docs/incident-response.md) — P1-P4 處理手冊 (嚴重度、SLA、升級)
- [`docs/metrics-and-kpi.md`](docs/metrics-and-kpi.md) — 領先與落後指標、儀表板版型
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) — 跨區故障切換、RTO/RPO

### 給 CISO / 風控 / 稽核 / 法遵
- [`docs/data-classification.md`](docs/data-classification.md) — Claude Code 可能處理的資料類別
- [`docs/third-party-risk.md`](docs/third-party-risk.md) — Anthropic / AWS / npm 廠商風險評估
- [`docs/sbom.md`](docs/sbom.md) — 軟體物料清單 (EO 14028、EU CRA)
- [`docs/maintenance-schedule.md`](docs/maintenance-schedule.md) — 版本升級測試、RACI 矩陣

### 設定檔 (即用型)
- [`docs/managed-settings.jsonc`](docs/managed-settings.jsonc) — 企業 managed-settings.json (Level 1)
- [`docs/settings-linux-macos.jsonc`](docs/settings-linux-macos.jsonc) — User settings.json (Linux/macOS)
- [`docs/settings-windows.jsonc`](docs/settings-windows.jsonc) — User settings.json (Windows)

## 專案結構

```
claude-code-enterprise-bedrock/
├── README.md                              ← English version
├── README.zh-TW.md                        ← 本檔
├── LICENSE                                ← Apache 2.0
├── docs/                                  ← 18 個 markdown + 3 個 JSONC 設定檔
│   ├── bedrock-guardrails.md              ← Bedrock Guardrails 整合指南
│   ├── deployment-guide.md
│   ├── operations-runbook.md
│   ├── maintenance-schedule.md
│   ├── disaster-recovery.md
│   ├── incident-response.md
│   ├── metrics-and-kpi.md
│   ├── security-rationale.md
│   ├── threat-model.md
│   ├── data-classification.md
│   ├── third-party-risk.md
│   ├── sbom.md
│   ├── pii-guard.md
│   ├── known-issues.md
│   ├── test-results.md
│   ├── managed-settings.jsonc             ← Level 1 設定 (IT 部署)
│   ├── settings-linux-macos.jsonc         ← Level 2 設定 (使用者)
│   └── settings-windows.jsonc             ← Level 2 設定 (使用者,Windows)
├── hooks/                                 ← 全數測試通過 ✅
│   ├── git-guard.sh                       ← 企業 git 政策
│   ├── pii-guard.sh                       ← PII/機密掃描器 (Linux/macOS)
│   ├── pii-guard.ps1                      ← PII/機密掃描器 (Windows)
│   └── audit-logger.sh                    ← Append-only 稽核日誌
└── scripts/
    ├── wrapper-linux.sh                   ← 拒絕繞過旗標 (Linux/macOS) ✅
    ├── wrapper-windows.cmd                ← 拒絕繞過旗標 (Windows) ✅
    └── logrotate-claude-code.conf         ← 稽核日誌旋轉 (處理 chattr +a)
```

## 測試環境

| 元件 | 版本 |
|---|---|
| Claude Code | 2.1.150, 2.1.152, 2.1.156 |
| Linux | Amazon Linux 2023 (EC2 t3.medium) |
| Windows | Windows Server 2022 (EC2 t3.medium) |
| Node.js | 20.18.0, 20.20.2 LTS |
| PowerShell | 7.4.6 (Windows) |
| AWS Bedrock | us-east-1 透過 VPC Endpoint (private DNS) |
| Sandbox | bubblewrap 0.10.0 + socat 1.7.4.2 (Linux) |
| 模型 | `us.anthropic.claude-sonnet-4-6`, `us.anthropic.claude-haiku-4-5-20251001-v1:0` |

### 最低版本需求

本套件的部分功能需要特定 Claude Code 版本:

| 功能 | 最低版本 |
|---|---|
| `sandbox.network.deniedDomains` | v2.1.113+ |
| `managed-settings.d/` 目錄支援 | v2.1.83+ |
| `DISABLE_AUTOUPDATER` 環境變數 | v2.1.118+ |
| `ANTHROPIC_BEDROCK_SERVICE_TIER` | v2.1.122+ |

## 授權與貢獻

採用 [Apache 2.0](LICENSE) 授權 — 可自由用於企業部署。

**歡迎貢獻:**
- 新的 PII patterns (例如各國身分證號)
- 平台特定測試 (macOS、NFS home dirs、btrfs)
- 額外的 hook scripts (例如自訂 MCP server 驗證)
- README 翻譯

開 PR 時請附上測試證據 (來自 EC2 或本機 VM 的 shell log)。
