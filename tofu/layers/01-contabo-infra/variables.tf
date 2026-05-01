# tofu/layers/01-contabo-infra/variables.tf
variable "account_key" {
  type        = string
  description = "Contabo account key this layer instance manages. Each contabo account gets its own state file (production/01-contabo-infra-<account_key>.tfstate); the workflow runs accounts as a fail-fast=false matrix so one account's failure can't block the others. Must be a member of `contabo:` in tofu/shared/accounts.yaml."

  validation {
    condition     = contains(yamldecode(file("${path.module}/../../shared/accounts.yaml")).contabo, var.account_key)
    error_message = "account_key must be listed under `contabo:` in tofu/shared/accounts.yaml. A typo here would silently produce an empty layer; failing plan is the safer default."
  }
}

variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}


variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token, Zone:DNS:Edit. Kept in this layer ONLY to destroy the legacy cp_dns records still in its state — the new publishing path lives in layer 03. Remove once layer 01's state is clean of cloudflare_dns_record resources."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID; used for the S3-compatible AWS provider endpoint."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Module reads use this; writes go directly to R2."
}

variable "omni_siderolink_url" {
  type        = string
  default     = ""
  description = "Full siderolink URL injected into the boot cmdline, e.g. https://cp.antinvestor.com?jointoken=<token>. Empty string disables (transitional during the migration; non-empty after Phase A lands)."
}

variable "force_reinstall_generation" {
  type        = number
  default     = 1
  description = <<-EOT
    Operator escape hatch for forcing a fleet-wide Contabo VPS
    reinstall on next apply, decoupled from schematic_id changes.
    Bump in terraform.tfvars (e.g. 1 → 2) to invalidate every
    null_resource.ensure_image trigger; ensure-image.sh runs with
    FORCE_REINSTALL=1 and PUTs unconditionally regardless of
    current imageId.

    Use cases:
      - Recover from "stuck Talos" / lost SideroLink registration.
      - Refresh kernel cmdline after Omni's join token rotates.
      - Smoke-test reinstall paths.

    Routine reinstalls driven by a real schematic change still fire
    automatically through the target_image_id trigger; this knob
    only matters for "want a reinstall NOW".
  EOT
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}
