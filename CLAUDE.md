# CLAUDE.md

This repo ships OpenZiti controller events into Microsoft Sentinel via a push-based,
Azure-native pipeline: OpenZiti's native Service Bus event sink -> Azure Service Bus ->
an Azure Function -> the Logs Ingestion API -> a Sentinel custom table (with analytics
rules and a workbook). Terraform-provisioned, one command up, one command down. An
optional demo OpenZiti controller on Azure Container Instances generates real events so
the pipeline can be seen working end to end without a production controller.

## Key paths

- `terraform/` - root module: Service Bus, Function, DCE/DCR, Sentinel table/rules/workbook,
  optional demo ACI controller.
- `function/` - the ingestion Function (Python) plus its tests (`function/tests`).
- `scripts/` - `deploy.sh`, `verify.sh`, `teardown.sh`, and a sample event injector.
- `docs/` - `architecture.md` and `troubleshooting.md`.

## Commands

- `mise install` - install pinned tool versions (terraform, python, tflint).
- `./scripts/deploy.sh` / `./scripts/verify.sh` / `./scripts/teardown.sh` - stand up,
  check, and tear down the environment.
- `cd function && pytest` - run the Function's unit tests.

## Rules

- Run the repo's linters before pushing: super-linter (via `LukeEvansTech/shared-workflows`),
  `terraform fmt` / `terraform validate`, `tflint`, and `pytest`.
- Never commit `terraform.tfvars` or anything containing subscription IDs, tenant IDs,
  IP addresses, or email addresses - this repo is public.
