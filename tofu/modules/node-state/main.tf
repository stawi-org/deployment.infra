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

  # Only Contabo currently needs auth encryption (OAuth2 secrets).
  # Oracle auth carries non-sensitive pointers only (actual tokens come
  # from GitHub OIDC at runtime). On-prem has no auth.
  is_encrypted_auth = var.provider_name == "contabo"
}

# --- 404-safe existence probe -----------------------------------------------
# List the account prefix once; gate every read on the result so a missing
# key never causes aws_s3_object to throw a 404 during refresh.

data "aws_s3_objects" "inventory" {
  bucket = var.bucket
  prefix = "${local.base_key}/"
}

locals {
  inventory_keys      = toset(data.aws_s3_objects.inventory.keys)
  has_auth            = contains(local.inventory_keys, local.auth_key)
  has_nodes           = contains(local.inventory_keys, local.nodes_key)
  has_state           = contains(local.inventory_keys, local.state_key)
  has_talos_state     = contains(local.inventory_keys, local.talos_state_key)
  has_machine_configs = contains(local.inventory_keys, local.machine_configs_key)
}

# --- plaintext reads -------------------------------------------------------

data "aws_s3_object" "nodes" {
  count  = local.has_nodes ? 1 : 0
  bucket = var.bucket
  key    = local.nodes_key
}

data "aws_s3_object" "state" {
  count  = local.has_state ? 1 : 0
  bucket = var.bucket
  key    = local.state_key
}

data "aws_s3_object" "talos_state" {
  count  = local.has_talos_state ? 1 : 0
  bucket = var.bucket
  key    = local.talos_state_key
}

# --- encrypted reads (auth + machine-configs) ------------------------------
# aws_s3_object fetches the raw encrypted bytes; we write them to a local
# file so sops_file can point at them. local_sensitive_file isolates the
# plaintext from normal `tofu show`.

data "aws_s3_object" "auth_raw" {
  count  = local.is_encrypted_auth && local.has_auth ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
}

data "aws_s3_object" "machine_configs_raw" {
  count  = local.has_machine_configs ? 1 : 0
  bucket = var.bucket
  key    = local.machine_configs_key
}

# Non-contabo auth is plaintext.
data "aws_s3_object" "auth_raw_plain" {
  count  = !local.is_encrypted_auth && local.has_auth ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
}

# Stage encrypted bodies to disk so sops_file can decrypt them.
resource "local_sensitive_file" "auth_staged" {
  count    = local.is_encrypted_auth && local.has_auth ? 1 : 0
  filename = "${path.module}/.staged/auth-${var.provider_name}-${var.account}.age.yaml"
  content  = data.aws_s3_object.auth_raw[0].body
}

resource "local_sensitive_file" "machine_configs_staged" {
  count    = local.has_machine_configs ? 1 : 0
  filename = "${path.module}/.staged/machine-configs-${var.provider_name}-${var.account}.age.yaml"
  content  = data.aws_s3_object.machine_configs_raw[0].body
}

data "sops_file" "auth" {
  count       = local.is_encrypted_auth && local.has_auth ? 1 : 0
  source_file = local_sensitive_file.auth_staged[0].filename
}

data "sops_file" "machine_configs" {
  count       = local.has_machine_configs ? 1 : 0
  source_file = local_sensitive_file.machine_configs_staged[0].filename
}

# --- decoded outputs -------------------------------------------------------

locals {
  auth_decoded = (
    local.is_encrypted_auth
    ? (local.has_auth ? yamldecode(data.sops_file.auth[0].raw) : null)
    : (local.has_auth ? yamldecode(data.aws_s3_object.auth_raw_plain[0].body) : null)
  )

  nodes_decoded = (
    local.has_nodes
    ? yamldecode(data.aws_s3_object.nodes[0].body)
    : { nodes = {} }
  )

  state_decoded = (
    local.has_state
    ? yamldecode(data.aws_s3_object.state[0].body)
    : { nodes = {} }
  )

  talos_state_decoded = (
    local.has_talos_state
    ? yamldecode(data.aws_s3_object.talos_state[0].body)
    : { nodes = {} }
  )

  machine_configs_decoded = (
    local.has_machine_configs
    ? yamldecode(data.sops_file.machine_configs[0].raw)
    : { nodes = {} }
  )
}
