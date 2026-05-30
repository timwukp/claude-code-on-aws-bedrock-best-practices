# 安全部署 Claude Code on AWS Bedrock — 企業部署套件

> 經過實機測試的安全配置、Hook、IaC 模組、可觀測性,以及可重現的驗證套件,
> 用於在受監管的企業環境(銀行、醫療、政府)中,
> 在 [Amazon Bedrock](https://aws.amazon.com/bedrock/) 上部署 [Claude Code](https://code.claude.com)。

[English Version](README.md)

---

## 目錄

- [為什麼需要這個套件](#為什麼需要這個套件)
- [內含什麼](#內含什麼)
- [深度防禦架構](#深度防禦架構)
- [設定階層](#設定階層)
- [快速開始 (5 分鐘)](#快速開始-linuxmacos5-分鐘)
- [被攔截的內容](#被攔截的內容)
- [平台差異](#平台差異)
- [測試套件與可重現證據](#測試套件與可重現證據)
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
- 失控的 agent 迴圈把 Bedrock token 預算燒光

在受監管的環境裡,這是不可接受的。本套件提供**經過測試的控制機制** ——
附帶可重現的證據 —— 在不影響開發者生產力的前提下,鎖定 Claude Code。

## 內含什麼

這個套件不只是設定檔,是一個完整的維運套件:

| 層次 | 內容 |
|---|---|
| **強化的 Hooks** | 6 個 production hook —— PII guard、git guard、audit logger(HMAC chain)、token 預算斷路器、hook 遙測 shim、Windows PowerShell PII guard |
| **Wrappers** | 拒絕繞過旗標、sudoers-based 權限隔離、稽核日誌旋轉 |
| **即時漂移偵測** | inotify/fswatch watcher,偵測時間 <100ms,可設定 per-host watchlist |
| **基礎設施即程式碼 (IaC)** | EC2 基礎(IAM + SSM + CloudWatch)Terraform 模組 + SSM Parameter Store-backed MCP 允許清單 |
| **可觀測性** | CloudWatch dashboard + alarm(hook 崩潰率、延遲 p99、漂移事件) |
| **驗證套件** | 7 個測試套件、75+ 個斷言:PII corpus FNR/FPR、稽核鏈篡改偵測、紅隊繞過(32 次嘗試)、延遲基準、Bedrock Guardrails 線上驗證 |
| **維運文件** | 威脅模型(STRIDE)、事件回應、值班 runbook、hook 合約、平台補償控制、測試證據、部署指南 |

## 深度防禦架構

七層強制執行機制,全部在實際 AWS 環境測試過:

| 層級 | 機制 | 攔下什麼 | 詳細文件 |
|---|---|---|---|
| 1 | **權限拒絕規則** | 單 token 危險指令 | [`docs/security-rationale.md`](docs/security-rationale.md) |
| 2 | **`pii-guard.sh`** Hook | Prompt 與工具輸入中的敏感資料 | [`docs/pii-guard.md`](docs/pii-guard.md) |
| 3 | **`git-guard.sh`** Hook | 未授權 git push、分支違規、force-push | [hook 原始碼](hooks/git-guard.sh) |
| 4 | **`audit-logger.sh`** Hook(HMAC 鏈、fail-closed) | 規避稽核、偽造稽核日誌 | [hook 原始碼](hooks/audit-logger.sh) |
| 5 | **`token-budget-guard.sh`** Hook | Token 費用爆炸、失控的 agent session | [hook 原始碼](hooks/token-budget-guard.sh) |
| 6 | **Wrapper Script + 檔案系統 ACL + sudoers** | `--dangerously-skip-permissions`、`--permission-mode=…`、`claude mcp add` | [wrapper-linux.sh](scripts/wrapper-linux.sh) |
| 7 | **Bedrock Guardrails**(伺服器端) | 有害內容、PII、prompt-attack jailbreak | [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) |

加上 **作業系統沙盒**(bubblewrap)、**網路隔離**(VPC Endpoint)、
**遙測 shim**([`hooks/hook-wrapper.sh`](hooks/hook-wrapper.sh))將 hook 崩潰/逾時轉成 fail-closed 拒絕、
**即時漂移 watcher**([`scripts/drift-watcher.sh`](scripts/drift-watcher.sh))
對 managed config 或 hook 檔案的任何改動 ~60ms 內就告警。

完整的 STRIDE 攻擊樹分析請參考 [`docs/threat-model.md`](docs/threat-model.md);
驗證過的效能與安全數據見 [`docs/test-evidence.md`](docs/test-evidence.md)。

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

下方是手動安裝指令。**production 環境建議使用 Terraform 模組**
[`terraform/ec2-baseline/`](terraform/ec2-baseline/),整個部署是 idempotent + SSM-driven。

```bash
# 0. 安裝 Claude Code
curl -fsSL https://claude.ai/install.sh | bash          # macOS / Linux
# 其他: brew install --cask claude-code | irm https://claude.ai/install.ps1 | iex (Windows)

# 1. 安裝相依套件
sudo dnf install -y bubblewrap socat jq inotify-tools openssl    # 或 apt install ...

# 2. 部署 hooks (root 擁有,可執行)
sudo mkdir -p /usr/local/etc/claude-code/hooks
sudo cp hooks/*.sh /usr/local/etc/claude-code/hooks/
sudo chown root:root /usr/local/etc/claude-code/hooks/*.sh
sudo chmod 0755 /usr/local/etc/claude-code/hooks/*.sh

# 3. 部署 managed settings (root 擁有)
sudo mkdir -p /etc/claude-code
python3 -c "import re,json;c=open('docs/managed-settings.jsonc').read();c=re.sub(r'(?<!:)//[^\n]*','',c);c=re.sub(r'/\*.*?\*/','',c,flags=re.S);c=re.sub(r',(\s*[}\]])',r'\1',c);json.dump(json.loads(c),open('/tmp/m.json','w'),indent=2)"
sudo mv /tmp/m.json /etc/claude-code/managed-settings.json

# 4. 部署強化 wrapper + sudoers (real binary 0750 root:claude-users)
sudo groupadd claude-users 2>/dev/null || true
sudo mkdir -p /opt/claude-code/bin
sudo install -m 0750 -o root -g claude-users $(which claude) /opt/claude-code/bin/claude
sudo install -m 0755 -o root -g root scripts/wrapper-linux.sh /usr/local/bin/claude
sudo install -m 0440 -o root -g root scripts/sudoers-claude-code /etc/sudoers.d/claude-code
sudo visudo -cf /etc/sudoers.d/claude-code

# 5. 鎖定 MCP 設定 (阻止 `claude mcp add`)
touch ~/.claude.json && sudo chattr +i ~/.claude.json

# 6. 稽核日誌 + 旋轉 (HMAC 鏈預設啟用)
sudo mkdir -p /var/log/claude-code /var/lib/claude-code/audit-state
sudo touch /var/log/claude-code/audit.jsonl /var/log/claude-code/hooks.jsonl /var/log/claude-code/drift.jsonl
sudo chattr +a /var/log/claude-code/audit.jsonl
sudo cp scripts/logrotate-claude-code.conf /etc/logrotate.d/claude-code

# 7. 即時漂移 watcher (systemd 服務)
sudo install -m 0755 scripts/drift-watcher.sh /usr/local/bin/claude-drift-watcher
# (對應的 systemd unit 在 terraform/ec2-baseline/ssm-deploy.yaml.tpl)

# 8. 驗證
claude -p "say PONG"                                # → PONG (正常)
claude -p "My card is 4111-1111-1111-1111"          # → 被擋 (PII guard)
claude -p "hi" --dangerously-skip-permissions       # → Refused (wrapper)
claude -p "x" --permission-mode=bypassPermissions   # → Refused (wrapper, 等號形式)
echo "Run: curl http://example.com" | claude -p --allowedTools Bash  # → denied

# 9. 跑本機測試套件 (75+ 斷言,macOS 約 3 分鐘)
bash tests/run_all.sh    # → "7 suites passed, 0 failed"
```

完整部署 (含 Terraform、黃金映像、跨區域) 請見
[`docs/deployment-guide.md`](docs/deployment-guide.md)。

## 被攔截的內容

### PII 與機密 —— 本機 hook(經 corpus 驗證)

108 個 PII 案例 → **FNR 0%、FPR 0%、p95 ≤ 484ms**(見
[`docs/test-evidence.md`](docs/test-evidence.md))。

| 資料類型 | 範例 | 結果 |
|---|---|---|
| 信用卡(16 位 + Amex 4-6-5) | `4111-1111-1111-1111`、`3782 822463 10005` | ✅ 攔截 |
| AWS keys | `AKIAIOSFODNN7EXAMPLE` | ✅ 攔截 |
| 私鑰 | `-----BEGIN RSA PRIVATE KEY-----` | ✅ 攔截 |
| JWT tokens | `eyJhbG...`(3 段 base64url) | ✅ 攔截 |
| 密碼 | `password=SuperSecret123!` | ✅ 攔截 |
| 新加坡 NRIC | `S1234567D` | ✅ 攔截 |
| 電話(國際、多分隔)、護照、Email | 各種 | ✅ 攔截 |
| GitHub/GitLab/Slack tokens | `ghp_...`, `xoxb-...` | ✅ 攔截 |
| DB 連線字串 | `postgres://user:pass@host/db` | ✅ 攔截 |
| 通用 API key 賦值 | `api_key=...`, `access_token=...` | ✅ 攔截 |
| Hex 機密(32+ hex,含字母) | `e3b0c44298fc1c149afbf4c8996fb924...` | ✅ 攔截 |
| 一般 prompt | `"寫一個排序函數"` | ✅ 通過 |

完整清單與客製化: [`docs/pii-guard.md`](docs/pii-guard.md)。

### 危險指令(被規則或 hook 拒絕)

| 指令 | Linux | Windows |
|---|---|---|
| `rm -rf *` / `Remove-Item -Recurse` | ✅ 拒絕 | ✅ 拒絕 |
| `git push` 到未授權 remote | ✅ Hook 攔截 | ✅ 拒絕 |
| `git push` 到 feature 分支(允許的 remote) | ✅ **允許** | ✅ **允許** |
| `git push` 到受保護分支(main/master) | ✅ Hook 攔截 | ✅ 拒絕 |
| `git push --force` / `--force-with-lease` | ✅ Hook 攔截 | ✅ 拒絕 |
| `git remote add`(未授權網域) | ✅ Hook 攔截 | ✅ 拒絕 |
| `git remote add`(允許的網域) | ✅ **允許** | ✅ **允許** |
| `git reset --hard` / `git clean -fd` | ✅ Hook 攔截 | ✅ 拒絕 |
| `curl` / `wget` / `Invoke-WebRequest` | ✅ 拒絕 | ✅ 拒絕 |
| `sudo` / `Set-ExecutionPolicy` | ✅ 拒絕 | ✅ 拒絕 |
| `aws iam` / `aws sts` / `aws secretsmanager` | ✅ 拒絕 | ✅ 拒絕 |
| 讀取 `.env` / `.aws/credentials` / `.ssh/` | ✅ 拒絕 | ☑️ 改用 sandbox.denyRead |
| 寫入 `C:\Windows\` | N/A | ✅ 拒絕 |

### 繞過嘗試(紅隊驗證 —— 32/32 全部攔下)

| 繞過方式 | 結果 |
|---|---|
| `--dangerously-skip-permissions` | ✅ Wrapper 拒絕 |
| `--allow-dangerously-skip-permissions` | ✅ 拒絕 |
| `--permission-mode auto` / `bypassPermissions` | ✅ 拒絕 |
| `--permission-mode=bypassPermissions`(等號形式) | ✅ 拒絕 |
| `--bare`(跳過 hooks) | ✅ 拒絕 |
| `claude mcp add --scope user` | ✅ EPERM (chattr +i) |
| Force-push 藏在 `&&` 之後(複合 shell) | ✅ git-guard 抓到 |
| Hook crash → 靜默通過 | ✅ 遙測 shim 轉成 fail-closed |
| `CLAUDE_AUDIT_LOG=/dev/null`(消音稽核) | ✅ Managed env 覆蓋;若 log 不可寫則 fail-closed |

完整繞過測試套件:[`tests/bypass-attempts.sh`](tests/bypass-attempts.sh)。

### Token 費用爆炸(斷路器)

`token-budget-guard.sh` 強制執行每 session 的 token + 工具呼叫預算。
當 session 達到 `CLAUDE_TOKEN_BUDGET`(預設 1M tokens)或
`CLAUDE_CALL_BUDGET`(預設 500 次呼叫),下一個 `PreToolUse` 回傳
exit 2,使用者必須開新 session。

### Bedrock Guardrails(伺服器端,線上驗證過)

| 政策 | 狀態 | 備註 |
|---|---|---|
| Content Filters(Hate/Insults/Sexual/Violence/Misconduct) | ✅ 可用 | Input + Output |
| **`PROMPT_ATTACK` filter** | ✅ 可用(5/5 jailbreak 被攔) | 推翻了 #63637「不能用」的說法 |
| Denied Topics | ✅ 可用 | 100% recall、16.7% FPR —— 須校準定義 |
| Word Filters | ✅ 可用 | 自訂 + AWS 內建髒話清單 |
| Sensitive Information Filters | ⚠️ 美國中心 | 本機 pii-guard.sh 補(NRIC、國際電話等) |
| Contextual Grounding | ⚠️ 條件性 | **沒帶 `grounding_source` 的請求會直接 error** —— 一般 code-gen 不要啟用 |
| Streaming intervention UX | ⚠️ 陷阱 | 把 `blockedInputMessaging`(預設 `BLOCKED_INPUT_BY_GUARDRAIL`)當一般文字 delta 回傳 —— Claude Code 會當模型輸出顯示。**請自訂**為明顯非模型風格的字串(上限 500 字元,已驗證 verbatim,見 [`docs/bedrock-guardrails.md#streaming-ux-gotcha-read-this`](docs/bedrock-guardrails.md#streaming-ux-gotcha-read-this)) |

可重現測試:[`tests/aws-guardrails/`](tests/aws-guardrails/)。
完整證據:[`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md)。

## 平台差異

| 行為 | Linux/macOS (Bash) | Windows (PowerShell) |
|---|---|---|
| `<tool>(git push *)` deny | ☑️ 改用 `:*` 語法 (Bash matcher bug) | ✅ 直接可用 |
| `<tool>(git remote add *)` deny | ☑️ 改用 git-guard.sh hook | ✅ 直接可用 |
| `Read(**/.env)` deny | ✅ 可用 | ☑️ 改用 sandbox.denyRead |
| OS sandbox (bubblewrap) | ✅ 支援 | ❌ 原生不支援 |
| PII guard 範圍 | ✅ UserPromptSubmit + PreToolUse | ☑️ 僅 PreToolUse(`UserPromptSubmit` 在 Windows `--print` 模式不會觸發;以 Bedrock Guardrails 補 prompt 階段 PII) |
| `chattr +i` 鎖 MCP | ✅ ext4/xfs | ☑️ 改用 `icacls` (Win) 或 **`sudo chflags schg`** (macOS — 注意 `chflags uchg` 用戶可自解,須用 `schg` + 非 root 用戶。見 known-issues Issue 11) |
| NFS home 目錄 | ❌ `chattr` 無作用 —— 見補償控制 | ❌ 同上 |

各平台補償控制:[`docs/platform-compensations.md`](docs/platform-compensations.md)。
完整平台相容性: [`docs/known-issues.md`](docs/known-issues.md)。

## 測試套件與可重現證據

本套件附帶 7 個套件、75+ 斷言的測試框架。文件中的每一個聲明,
都有可重現的測試背書。

```bash
bash tests/run_all.sh
# === 1. PII corpus (FNR/FPR) ===            FNR=0.00%  FPR=0.00%  p95=484ms
# === 2. Hook telemetry shim ===             passed=12 failed=0
# === 3. Audit HMAC chain ===                passed=13 failed=0
# === 4. Token budget guard ===              passed=9  failed=0
# === 5. Drift watcher self-test ===         drift detected in 47ms
# === 6. Bypass red-team harness ===         passed=32 failed=0   (5 類別,32/32 攔截)
# === 7. Hook latency micro-bench ===        所有 hook p99 ≤ 490ms (macOS 開發機)
# RUN-ALL: 7 suites passed, 0 failed
```

Bedrock Guardrails 線上驗證(需要 AWS 帳號,約 $0.35 美元):

```bash
bash   tests/aws-guardrails/01_create_guardrail.sh        # 建立測試 guardrail
python3 tests/aws-guardrails/02_streaming.py              # streaming + 非 streaming
python3 tests/aws-guardrails/03_pii_detection.py          # PII corpus 對 Bedrock
python3 tests/aws-guardrails/04_cross_region.py           # us.* 與 global.* profiles
python3 tests/aws-guardrails/06_denied_topics.py          # FPR 量測
python3 tests/aws-guardrails/08_latency.py                # 30 次延遲基準
python3 tests/aws-guardrails/09_grounding.py              # Contextual Grounding
python3 tests/aws-guardrails/10_prompt_attack.py          # PROMPT_ATTACK 帶/不帶 tags
aws bedrock delete-guardrail --guardrail-identifier <id>  # 清理
```

測試套件揪出的 bug(然後修掉):
- `pii-guard.sh` 5 個 regex 缺陷(Amex CC、國際電話、通用 API key、hex 假陽性、護照假陽性)
- 1 個 wrapper 繞過(`--permission-mode=bypassPermissions` 等號形式)
- 1 個 silent 稽核遺失 bug(`exit 0` 失敗時靜默 —— 現已 fail-closed + HMAC chain)

完整數據與 value-add 稽核紀錄見 [`docs/test-evidence.md`](docs/test-evidence.md)
與 [`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md)。

## 文件索引

文件依受眾與用途分組。

### 給開發者 / IT 維運(部署與執行)
- [`docs/deployment-guide.md`](docs/deployment-guide.md) — 黃金映像逐步檢查清單
- [`docs/operations-runbook.md`](docs/operations-runbook.md) — Onboarding、offboarding、緊急停用、憑證輪替
- [`docs/runbooks/on-call.md`](docs/runbooks/on-call.md) — 各告警對應的回應程序(對應 `observability/` 中的 CloudWatch alarms)
- [`docs/known-issues.md`](docs/known-issues.md) — Matcher bug、平台特性、已驗證 workaround
- [`docs/platform-compensations.md`](docs/platform-compensations.md) — NFS / Windows `--print` / macOS / Kubernetes 補償控制
- [`docs/hook-contract.md`](docs/hook-contract.md) — Hook 輸入/輸出 schema、exit code 語意、遙測 schema、稽核日誌 schema
- [`docs/test-results.md`](docs/test-results.md) — 原始 Linux + Windows e2e 測試證據
- [`docs/test-evidence.md`](docs/test-evidence.md) — 本機測試套件結果(PII、hooks、稽核鏈、繞過、延遲)

### 給安全團隊(審查、監控、回應)
- [`docs/threat-model.md`](docs/threat-model.md) — STRIDE 分析與攻擊樹
- [`docs/security-rationale.md`](docs/security-rationale.md) — 威脅 → 控制 對應表
- [`docs/pii-guard.md`](docs/pii-guard.md) — PII guard hook 細節與客製化
- [`docs/bedrock-guardrails.md`](docs/bedrock-guardrails.md) — AWS Bedrock Guardrails 整合指南(7 層防護策略、配置、已驗證行為)
- [`docs/bedrock-guardrails-test-evidence.md`](docs/bedrock-guardrails-test-evidence.md) — 線上驗證:streaming 行為、CloudWatch metrics、PII 分類、延遲、prompt attack
- [`docs/incident-response.md`](docs/incident-response.md) — P1-P4 處理手冊(嚴重度、SLA、升級)
- [`docs/metrics-and-kpi.md`](docs/metrics-and-kpi.md) — 領先與落後指標、儀表板版型
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) — 跨區故障切換、RTO/RPO

### 給 CISO / 風控 / 稽核 / 法遵
- [`docs/data-classification.md`](docs/data-classification.md) — Claude Code 可能處理的資料類別
- [`docs/third-party-risk.md`](docs/third-party-risk.md) — Anthropic / AWS / npm 廠商風險評估
- [`docs/sbom.md`](docs/sbom.md) — 軟體物料清單 (EO 14028、EU CRA)
- [`docs/maintenance-schedule.md`](docs/maintenance-schedule.md) — 版本升級測試、RACI 矩陣

### 設定檔(即用型)
- [`docs/managed-settings.jsonc`](docs/managed-settings.jsonc) — 企業 managed-settings.json (Level 1)
- [`docs/settings-linux-macos.jsonc`](docs/settings-linux-macos.jsonc) — User settings.json (Linux/macOS)
- [`docs/settings-windows.jsonc`](docs/settings-windows.jsonc) — User settings.json (Windows)

### 基礎設施即程式碼 (IaC)
- [`terraform/ec2-baseline/`](terraform/ec2-baseline/) — EC2 + IAM + SSM Document + CloudWatch 基線(idempotent 部署)
- [`terraform/managed-settings-ssm/`](terraform/managed-settings-ssm/) — 經 SSM Parameter Store 的核准 MCP server 清單
- [`observability/cloudwatch-dashboard.tf`](observability/cloudwatch-dashboard.tf) — Dashboard + 4 個 alarm(hook 崩潰率、p99 延遲、漂移事件、攔截率)

## 專案結構

```
claude-code-on-aws-bedrock-best-practices/
├── README.md                              ← English version
├── README.zh-TW.md                        ← 本檔
├── LICENSE                                ← Apache 2.0
├── docs/                                  ← 21 個 markdown + 3 個 JSONC 設定檔
│   ├── bedrock-guardrails.md              ← Bedrock Guardrails 整合指南
│   ├── bedrock-guardrails-test-evidence.md ← Guardrails 線上 AWS 驗證
│   ├── data-classification.md
│   ├── deployment-guide.md
│   ├── disaster-recovery.md
│   ├── hook-contract.md                   ← hook API 規格(輸入/輸出/exit code)
│   ├── incident-response.md
│   ├── known-issues.md
│   ├── maintenance-schedule.md
│   ├── managed-settings.jsonc             ← Level 1 設定 (IT 部署)
│   ├── metrics-and-kpi.md
│   ├── operations-runbook.md
│   ├── pii-guard.md
│   ├── platform-compensations.md          ← NFS / Windows / macOS / k8s
│   ├── runbooks/
│   │   └── on-call.md                     ← 各告警對應的回應程序
│   ├── sbom.md
│   ├── security-rationale.md
│   ├── settings-linux-macos.jsonc         ← Level 2 設定 (使用者)
│   ├── settings-windows.jsonc             ← Level 2 設定 (使用者,Windows)
│   ├── test-evidence.md                   ← 本機測試套件結果 + bug 稽核紀錄
│   ├── test-results.md                    ← 原始 Linux + Windows e2e 證據
│   ├── third-party-risk.md
│   └── threat-model.md
├── hooks/                                 ← 全數測試通過 ✅
│   ├── audit-logger.sh                    ← HMAC 鏈、fail-closed、CloudWatch dual-write
│   ├── git-guard.sh                       ← 企業 git 政策
│   ├── hook-wrapper.sh                    ← 任意 hook 的遙測 + fail-closed shim
│   ├── pii-guard.ps1                      ← PII/機密掃描器 (Windows)
│   ├── pii-guard.sh                       ← PII/機密掃描器 (Linux/macOS)
│   └── token-budget-guard.sh              ← agent loop 斷路器
├── scripts/
│   ├── chain-verify.sh                    ← 驗證稽核日誌 HMAC 鏈完整性
│   ├── drift-watcher.sh                   ← 即時篡改偵測 (inotify/fswatch)
│   ├── logrotate-claude-code.conf         ← 稽核日誌旋轉 (處理 chattr +a)
│   ├── sudoers-claude-code                ← 強化 wrapper 的 sudoers 設定
│   ├── wrapper-linux.sh                   ← 拒絕繞過旗標 (Linux/macOS)
│   └── wrapper-windows.cmd                ← 拒絕繞過旗標 (Windows)
├── terraform/
│   ├── ec2-baseline/                      ← EC2 + IAM + SSM + CloudWatch (idempotent)
│   │   ├── main.tf
│   │   ├── ssm-deploy.yaml.tpl
│   │   └── user-data.sh.tpl
│   └── managed-settings-ssm/              ← MCP 允許清單的 SSM Parameter Store
│       └── main.tf
├── observability/
│   └── cloudwatch-dashboard.tf            ← Dashboard + 4 個 alarm
└── tests/
    ├── aws-guardrails/                    ← Bedrock Guardrails 驗證(10 個腳本)
    │   ├── 01_create_guardrail.sh
    │   ├── 02_streaming.py
    │   ├── 03_pii_detection.py
    │   ├── 04_cross_region.py
    │   ├── 06_denied_topics.py
    │   ├── 08_latency.py
    │   ├── 09_grounding.py
    │   ├── 10_prompt_attack.py
    │   └── lib/invoke.py
    ├── lib/harness.sh                     ← 共用測試 helpers
    ├── pii-corpus/                        ← 108 個標記的 PII 測試案例
    │   ├── negative/
    │   └── positive/
    ├── bench_hook_latency.sh              ← 200 次延遲微基準
    ├── bypass-attempts.sh                 ← 32 次紅隊測試套件
    ├── run_all.sh                         ← master runner(7 個套件)
    ├── run_pii_corpus.sh                  ← 108 個 PII 案例驗證
    ├── test_audit_chain.sh                ← HMAC 鏈篡改偵測
    ├── test_hook_wrapper.sh               ← 遙測 + fail-closed 語意
    └── test_token_budget.sh               ← per-session 斷路器
```

## 測試環境

| 元件 | 版本 |
|---|---|
| Claude Code | 2.1.150, 2.1.152, 2.1.156 |
| Linux | Amazon Linux 2023 (EC2 t3.medium) |
| Windows | Windows Server 2022 (EC2 t3.medium) |
| macOS | Darwin 25.5 (arm64,開發機) |
| Node.js | 20.18.0, 20.20.2 LTS |
| PowerShell | 7.4.6 (Windows) |
| AWS CLI | v2.31.23 (macOS)、v2.33.15 (Linux EC2)、v2.34.56 (Windows EC2) |
| boto3 / botocore | 1.42.79 |
| AWS Bedrock | us-east-1 透過 VPC Endpoint (private DNS) |
| Sandbox | bubblewrap 0.10.0 + socat 1.7.4.2 (Linux) |
| 模型 | `us.anthropic.claude-sonnet-4-6`、`us.anthropic.claude-haiku-4-5-20251001-v1:0`、`global.*` profiles |
| Inference profiles | `us.*` 與 `global.*` 跨區域 —— 兩者皆與 guardrails 一起驗證過 |
| Terraform | ≥ 1.5.0 (HCL2 parser 驗證過) |

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
- 新的 PII patterns(例如各國身分證號) —— 在 `tests/pii-corpus/positive/` 加一筆 corpus,然後重跑 `bash tests/run_pii_corpus.sh` 證明 FNR
- 平台特定測試(macOS、NFS home dirs、btrfs)
- 額外的 hook scripts(例如自訂 MCP server 驗證)
- README 翻譯

開 PR 時請附上測試證據:
- Hook/regex 變動:`bash tests/run_all.sh` 輸出
- Bedrock 相關變動:`tests/aws-guardrails/` 輸出(account ID 須遮罩)
- 部署變動:來自 EC2 或本機 VM 的 shell log
