# tofu/modules/node-state/main.tf
#
# Reads per-(provider, account) inventory files from a LOCAL staging
# directory (populated by the workflow pre-plan via aws s3 sync from R2).
# Writes go directly to R2 via aws_s3_object resources.
#
# Agreed R2 layout (only these files live under <provider>/<account>/):
#   auth.yaml                        declarative credentials (sops for contabo)
#   nodes.yaml                       declarative node specs
#   <talos-version>/<node>.yaml      per-node Talos machine config
#
# Provider observed state (instance OCIDs, IPs, image_apply_generation)
# is NOT in this tree — it lives in each layer's tfstate and crosses
# layers via terraform_remote_state.

locals {
  base_key  = "${var.key_prefix}/${var.provider_name}/${var.account}"
  auth_key  = "${local.base_key}/auth.yaml"
  nodes_key = "${local.base_key}/nodes.yaml"

  # Only Contabo currently needs auth encryption (OAuth2 secrets).
  # Oracle auth carries non-sensitive pointers only (actual tokens come
  # from GitHub OIDC at runtime). On-prem has no auth.
  is_encrypted_auth = var.provider_name == "contabo"

  # Local staged paths (reads).
  base_local  = "${var.local_inventory_dir}/${var.provider_name}/${var.account}"
  auth_local  = "${local.base_local}/auth.yaml"
  nodes_local = "${local.base_local}/nodes.yaml"

  has_auth  = fileexists(local.auth_local)
  has_nodes = fileexists(local.nodes_local)
}

# --- encrypted reads (auth) ------------------------------------------------

data "sops_file" "auth" {
  count       = local.is_encrypted_auth && local.has_auth ? 1 : 0
  source_file = local.auth_local
}

# --- decoded outputs -------------------------------------------------------

locals {
  # Branch on is_encrypted_auth at the STRING level so both branches
  # produce strings that unify. yamldecode once afterwards.
  auth_raw_yaml = (
    local.is_encrypted_auth
    ? (local.has_auth ? data.sops_file.auth[0].raw : "")
    : (local.has_auth ? file(local.auth_local) : "")
  )
  auth_decoded = try(yamldecode(local.auth_raw_yaml), null)

  nodes_decoded = try(yamldecode(file(local.nodes_local)), { nodes = {} })
}

# Diagnostic: which inventory files were found.
locals {
  inventory_keys = sort(concat(
    local.has_auth ? [local.auth_local] : [],
    local.has_nodes ? [local.nodes_local] : [],
  ))
}

# --- writers ---------------------------------------------------------------

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

# Per-node Talos machine configs live under <account>/<talos_version>/
# as one YAML per node. Old version directories are left in place as an
# audit trail; a version bump produces a fresh directory alongside.
# Plaintext in R2 — contains cluster PKI material; security boundary is
# R2 access, same as the *.tfstate files in the same bucket.
resource "aws_s3_object" "per_node_config" {
  for_each = var.write_per_node_configs ? var.per_node_configs_content : {}
  bucket   = var.bucket
  key      = "${local.base_key}/${var.talos_version}/${each.key}.yaml"
  content  = yamlencode(each.value)
  # yamlencode on a full Talos machine config can be MB-sized; leave
  # content_type as generic text so R2's Content-Type header matches.
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = !var.write_per_node_configs || var.talos_version != ""
      error_message = "write_per_node_configs = true but talos_version is empty"
    }
  }
}
