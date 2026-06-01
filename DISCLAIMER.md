# Disclaimer

## Not affiliated with Anthropic or AWS

This is an independent, personal open-source project. It is **not** affiliated
with, endorsed by, sponsored by, or supported by Anthropic, Amazon Web Services
(AWS), or any other company. "Claude", "Claude Code", and "Anthropic" are
trademarks of Anthropic, PBC. "AWS", "Amazon Bedrock", and related marks are
trademarks of Amazon.com, Inc. or its affiliates. All trademarks are the
property of their respective owners and are used here only for descriptive,
nominative purposes to indicate compatibility.

## Security software — provided "AS IS", no warranty

This project provides security-related controls (PII/secret detection, git
policy enforcement, audit logging, budget limits). Security tooling is
inherently best-effort:

- The PII/secret detection validates **format only** (digit count, grouping,
  known token shapes). It does **not** validate government check-digit
  algorithms, and it **will** produce both false negatives (missed sensitive
  data) and false positives (benign data blocked).
- It is **not** a substitute for, and does **not** constitute, legal,
  regulatory, compliance, or professional security advice.
- It does **not** guarantee detection or prevention of any data leakage,
  breach, or policy violation, and does **not** guarantee compliance with any
  law, regulation, or standard (including but not limited to GLBA, HIPAA, GDPR,
  PCI DSS, PIPA, APPI, or any financial-regulator requirement referenced in the
  documentation).

You are solely responsible for evaluating, testing, and validating these
controls in your own environment before any reliance, and for your own
compliance obligations.

## No liability

To the maximum extent permitted by applicable law, the author(s) shall not be
liable for any claim, damages, loss, or other liability arising from or in
connection with the software or its use, whether in contract, tort, or
otherwise. This project is licensed under the Apache License 2.0; see the
[LICENSE](LICENSE) file, including its Disclaimer of Warranty (Section 7) and
Limitation of Liability (Section 8), which govern your use.

## Reference links

Links to official government and standards sources are provided for convenience
and reference only. They are not guaranteed to be current, complete, or
accurate; verify them at the official source before relying on them.

## Use at your own risk

By using this project you acknowledge and accept the above and assume all risk
arising from its use.
