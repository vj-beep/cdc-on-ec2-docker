# Contributing

Thank you for your interest in improving this CDC POC accelerator.

## Reporting Issues

Open a GitHub issue with:
- Which phase or script failed
- The exact error message (redact any credentials)
- Your OS, Docker version, and AWS region

## Suggesting Improvements

Open a GitHub issue describing:
- The problem you encountered or gap you found
- Your proposed solution or approach

## Submitting Pull Requests

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused — one logical change per commit.
3. Ensure scripts remain idempotent and respect the existing `.env` variable conventions.
4. Do not commit `.env` or any file containing credentials, IPs, or customer-specific data.
5. Open a pull request with a clear description of what changed and why.

## Guidelines

- **No credentials or internal references** — this is a public, customer-facing repo.
- **Environment-agnostic** — scripts should work for any deployment (Terraform, CloudFormation, manual). Use `.env` variables rather than hardcoded values.
- **Preserve the phase numbering** — scripts 0–7 must remain in order and self-contained.
- **Test before submitting** — if possible, run the affected phases end-to-end.
