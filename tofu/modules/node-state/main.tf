# tofu/modules/node-state/main.tf
#
# Reads five inventory files for (provider, account) from R2 and exposes
# decoded YAML. Missing files return {} so callers on first apply see an
# empty state and create-from-scratch.
#
# Encrypted files (auth.yaml, machine-configs.yaml) are decrypted via the
# carlpett/sops provider using SOPS_AGE_KEY from the environment.

locals {
  base_key = "${var.key_prefix}/${var.provider_name}/${var.account}"

  auth_key            = "${local.base_key}/auth.yaml"
  nodes_key           = "${local.base_key}/nodes.yaml"
  state_key           = "${local.base_key}/state.yaml"
  talos_state_key     = "${local.base_key}/talos-state.yaml"
  machine_configs_key = "${local.base_key}/machine-configs.yaml"
}

# --- plaintext reads -------------------------------------------------------

data "aws_s3_object" "nodes" {
  bucket = var.bucket
  key    = local.nodes_key
}

data "aws_s3_object" "state" {
  bucket = var.bucket
  key    = local.state_key
}

data "aws_s3_object" "talos_state" {
  bucket = var.bucket
  key    = local.talos_state_key
}

# --- encrypted reads (auth + machine-configs) ------------------------------
# aws_s3_object fetches the raw encrypted bytes; we write them to a local
# file so sops_file can point at them. local_sensitive_file isolates the
# plaintext from normal `tofu show`.

data "aws_s3_object" "auth_raw" {
  count  = var.provider_name == "contabo" ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
}

data "aws_s3_object" "machine_configs_raw" {
  bucket = var.bucket
  key    = local.machine_configs_key
}

locals {
  auth_raw_body = (
    var.provider_name == "contabo"
    ? try(data.aws_s3_object.auth_raw[0].body, "")
    : try(data.aws_s3_object.auth_raw_plain[0].body, "")
  )
  machine_configs_raw_body = try(data.aws_s3_object.machine_configs_raw.body, "")
}

# Non-contabo auth is plaintext.
data "aws_s3_object" "auth_raw_plain" {
  count  = var.provider_name == "contabo" ? 0 : 1
  bucket = var.bucket
  key    = local.auth_key
}

# Stage encrypted bodies to disk so sops_file can decrypt them.
resource "local_sensitive_file" "auth_staged" {
  count    = var.provider_name == "contabo" && local.auth_raw_body != "" ? 1 : 0
  filename = "${path.module}/.staged/auth-${var.provider_name}-${var.account}.age.yaml"
  content  = local.auth_raw_body
}

resource "local_sensitive_file" "machine_configs_staged" {
  count    = local.machine_configs_raw_body != "" ? 1 : 0
  filename = "${path.module}/.staged/machine-configs-${var.provider_name}-${var.account}.age.yaml"
  content  = local.machine_configs_raw_body
}

data "sops_file" "auth" {
  count       = var.provider_name == "contabo" && local.auth_raw_body != "" ? 1 : 0
  source_file = local_sensitive_file.auth_staged[0].filename
}

data "sops_file" "machine_configs" {
  count       = local.machine_configs_raw_body != "" ? 1 : 0
  source_file = local_sensitive_file.machine_configs_staged[0].filename
}

# --- decoded outputs -------------------------------------------------------

locals {
  auth_decoded = (
    var.provider_name == "contabo"
    ? try(yamldecode(data.sops_file.auth[0].raw), null)
    : try(yamldecode(data.aws_s3_object.auth_raw_plain[0].body), null)
  )

  nodes_decoded = try(
    yamldecode(data.aws_s3_object.nodes.body),
    { nodes = {} }
  )

  state_decoded = try(
    yamldecode(data.aws_s3_object.state.body),
    { nodes = {} }
  )

  talos_state_decoded = try(
    yamldecode(data.aws_s3_object.talos_state.body),
    { nodes = {} }
  )

  machine_configs_decoded = try(
    yamldecode(data.sops_file.machine_configs[0].raw),
    { nodes = {} }
  )
}
