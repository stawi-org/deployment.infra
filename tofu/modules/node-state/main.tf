# tofu/modules/node-state/main.tf
#
# Reads per-(provider, account) inventory files from a LOCAL staging
# directory (populated by the workflow pre-plan via aws s3 sync from R2).
# Writes go directly to R2 via aws_s3_object resources.
#
# Why local files for reads?  Provider configuration blocks are evaluated at
# plan time, so the Contabo provider's oauth2_* args must be known before
# plan resolves.  Earlier design used aws_s3_object -> local_sensitive_file
# (resource) -> sops_file which deferred decryption to apply time and
# handed the Contabo provider unknown values -> 401 "invalid_client".
# Reading from local files via fileexists()/file()/sops_file(source_file=<local>)
# keeps everything plan-time.
#
# The workflow syncs s3://cluster-tofu-state/production/inventory/ -> the
# directory in var.local_inventory_dir before tofu init runs.

locals {
  base_key = "${var.key_prefix}/${var.provider_name}/${var.account}"

  auth_key            = "${local.base_key}/auth.yaml"
  nodes_key           = "${local.base_key}/nodes.yaml"
  state_key           = "${local.base_key}/state.yaml"
  talos_state_key     = "${local.base_key}/talos-state.yaml"
  machine_configs_key = "${local.base_key}/machine-configs.yaml"

  # Only Contabo currently needs auth encryption (OAuth2 secrets).
  # Oracle auth carries non-sensitive pointers only (actual tokens come
  # from GitHub OIDC at runtime). On-prem has no auth.
  is_encrypted_auth = var.provider_name == "contabo"

  # Local staged paths.
  base_local            = "${var.local_inventory_dir}/${var.provider_name}/${var.account}"
  auth_local            = "${local.base_local}/auth.yaml"
  nodes_local           = "${local.base_local}/nodes.yaml"
  state_local           = "${local.base_local}/state.yaml"
  talos_state_local     = "${local.base_local}/talos-state.yaml"
  machine_configs_local = "${local.base_local}/machine-configs.yaml"

  has_auth            = fileexists(local.auth_local)
  has_nodes           = fileexists(local.nodes_local)
  has_state           = fileexists(local.state_local)
  has_talos_state     = fileexists(local.talos_state_local)
  has_machine_configs = fileexists(local.machine_configs_local)
}

# --- encrypted reads (auth + machine-configs) ------------------------------
# sops_file decrypts at refresh time (data source), values are known at
# plan time. No resource chain, no deferral to apply.

data "sops_file" "auth" {
  count       = local.is_encrypted_auth && local.has_auth ? 1 : 0
  source_file = local.auth_local
}

data "sops_file" "machine_configs" {
  count       = local.has_machine_configs ? 1 : 0
  source_file = local.machine_configs_local
}

# --- decoded outputs -------------------------------------------------------
#
# try() provides dynamic typing; it sidesteps OpenTofu's "inconsistent
# conditional result types" error (two literal-YAML decodes have different
# static object types). has_* predicates gate each data source, so try()
# rarely exercises its fallback in practice.

locals {
  # Branch on is_encrypted_auth at the STRING level (both branches produce
  # strings, which unify). Then yamldecode the resulting string once. This
  # avoids "Inconsistent conditional result types" that would otherwise fire
  # because the encrypted-file-on-disk has a `sops:` metadata key absent
  # from the decrypted sops_file.auth[0].raw output.
  auth_raw_yaml = (
    local.is_encrypted_auth
    ? (local.has_auth ? data.sops_file.auth[0].raw : "")
    : (local.has_auth ? file(local.auth_local) : "")
  )
  auth_decoded = try(yamldecode(local.auth_raw_yaml), null)

  nodes_decoded           = try(yamldecode(file(local.nodes_local)), { nodes = {} })
  state_decoded           = try(yamldecode(file(local.state_local)), { nodes = {} })
  talos_state_decoded     = try(yamldecode(file(local.talos_state_local)), { nodes = {} })
  machine_configs_decoded = try(yamldecode(data.sops_file.machine_configs[0].raw), { nodes = {} })
}

# Keep a summary of which files were found for downstream diagnostics.
locals {
  inventory_keys = sort(concat(
    local.has_auth ? [local.auth_local] : [],
    local.has_nodes ? [local.nodes_local] : [],
    local.has_state ? [local.state_local] : [],
    local.has_talos_state ? [local.talos_state_local] : [],
    local.has_machine_configs ? [local.machine_configs_local] : [],
  ))
}

# --- writers ---------------------------------------------------------------
# Encrypted writers use provider::sops::encrypt (OpenTofu 1.8+ provider-defined
# function). Plaintext writers skip encryption.

locals {
  recipients_joined = join(",", var.age_recipients)
}

resource "aws_s3_object" "auth" {
  count  = var.write_auth && local.is_encrypted_auth ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
  content = provider::sops::encrypt(
    yamlencode(var.auth_content),
    "yaml",
    { age = local.recipients_joined },
  )
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.auth_content != null
      error_message = "write_auth = true but auth_content is null"
    }
  }
}

resource "aws_s3_object" "auth_plaintext" {
  count        = var.write_auth && !local.is_encrypted_auth ? 1 : 0
  bucket       = var.bucket
  key          = local.auth_key
  content      = yamlencode(var.auth_content)
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.auth_content != null
      error_message = "write_auth = true but auth_content is null"
    }
  }
}

resource "aws_s3_object" "nodes" {
  count        = var.write_nodes ? 1 : 0
  bucket       = var.bucket
  key          = local.nodes_key
  content      = yamlencode(var.nodes_content)
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.nodes_content != null
      error_message = "write_nodes = true but nodes_content is null"
    }
  }
}

resource "aws_s3_object" "state" {
  count        = var.write_state ? 1 : 0
  bucket       = var.bucket
  key          = local.state_key
  content      = yamlencode(var.state_content)
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.state_content != null
      error_message = "write_state = true but state_content is null"
    }
  }
}

resource "aws_s3_object" "talos_state" {
  count        = var.write_talos_state ? 1 : 0
  bucket       = var.bucket
  key          = local.talos_state_key
  content      = yamlencode(var.talos_state_content)
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.talos_state_content != null
      error_message = "write_talos_state = true but talos_state_content is null"
    }
  }
}

resource "aws_s3_object" "machine_configs" {
  count  = var.write_machine_configs ? 1 : 0
  bucket = var.bucket
  key    = local.machine_configs_key
  content = provider::sops::encrypt(
    yamlencode(var.machine_configs_content),
    "yaml",
    { age = local.recipients_joined },
  )
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.machine_configs_content != null
      error_message = "write_machine_configs = true but machine_configs_content is null"
    }
  }
}
