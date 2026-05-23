# tofu/modules/node-state/main.tf
#
# Reads per-(provider, account) inventory state.
#
# Auth credentials live in the REPO under
#   tofu/shared/accounts/<provider>/<account>/auth.yaml
# (SOPS-encrypted via .sops.yaml at repo root). Node specs and per-node
# Talos configs live in R2 under production/inventory/<provider>/<account>/.
#
# Reads:
#   - auth.yaml is decrypted via the `sops` provider directly from the
#     repo path. No R2 round-trip, no local staging step.
#   - nodes.yaml is read from the local staging dir populated pre-plan
#     by `aws s3 sync s3://cluster-tofu-state/production/inventory/ <staging>/`.
# Writes (R2):
#   - nodes.yaml (observed provider_data is written back here on apply).
#   - <talos-version>/<node-key>.yaml (rendered Talos machine configs).

locals {
  base_key  = "${var.key_prefix}/${var.provider_name}/${var.account}"
  nodes_key = "${local.base_key}/nodes.yaml"

  # Repo-resident auth. Provider+account always present.
  auth_repo = "${path.module}/../../shared/accounts/${var.provider_name}/${var.account}/auth.yaml"

  # Local staged path for nodes.yaml.
  base_local  = "${var.local_inventory_dir}/${var.provider_name}/${var.account}"
  nodes_local = "${local.base_local}/nodes.yaml"

  has_auth  = fileexists(local.auth_repo)
  has_nodes = fileexists(local.nodes_local)
}

# --- encrypted reads (auth) ------------------------------------------------

data "sops_file" "auth" {
  count       = local.has_auth ? 1 : 0
  source_file = local.auth_repo
}

# --- decoded outputs -------------------------------------------------------

locals {
  # carlpett/sops returns a flat-dotted `data` map (e.g. "auth.tenancy_ocid")
  # which loses the nested shape layers expect (e.g. `mod.auth.auth.tenancy_ocid`).
  # Use `.raw` (decrypted YAML text) + yamldecode to preserve nesting.
  #
  # nonsensitive(): the sops provider marks every decrypted value as
  # sensitive, and that marking propagates through yamldecode + merge
  # into downstream `for_each` expressions. OpenTofu crashes when a
  # marked value reaches for_each ("value is marked, so must be unmarked
  # first"). Auth contents are OCI domain URLs, OCIDs, region strings,
  # and a single OIDC client_secret — none participate in production
  # plan output (just provider config); unmark so layer for_each over
  # oci_accounts_effective works.
  auth_decoded  = local.has_auth ? nonsensitive(yamldecode(data.sops_file.auth[0].raw)) : null
  nodes_decoded = try(yamldecode(file(local.nodes_local)), { nodes = {} })
}

# Diagnostic: which inventory files were found.
locals {
  inventory_keys = sort(concat(
    local.has_auth ? [local.auth_repo] : [],
    local.has_nodes ? [local.nodes_local] : [],
  ))
}

# --- writers (nodes + per-node configs) -----------------------------------

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
  # Values are already multi-document YAML strings (Talos emits
  # LinkConfig / HostnameConfig / MachineConfig as separate
  # documents joined by `---`). Write verbatim — yamldecode +
  # yamlencode would collapse the multi-doc boundaries.
  content      = each.value
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = !var.write_per_node_configs || var.talos_version != ""
      error_message = "write_per_node_configs = true but talos_version is empty"
    }
  }
}
