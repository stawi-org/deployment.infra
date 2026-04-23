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
#
# Both branches of each conditional call yamldecode() to avoid OpenTofu's
# "inconsistent conditional result types" error — yamldecode returns a
# dynamic type, so unifying the true/false branches is trivial when both
# go through it. The empty-file branch decodes a minimal literal string
# that produces the expected shape ({} or {nodes: {}}).

locals {
  auth_decoded = (
    local.is_encrypted_auth
    ? (local.has_auth ? yamldecode(data.sops_file.auth[0].raw) : yamldecode("{}"))
    : (local.has_auth ? yamldecode(data.aws_s3_object.auth_raw_plain[0].body) : yamldecode("{}"))
  )

  nodes_decoded = (
    local.has_nodes
    ? yamldecode(data.aws_s3_object.nodes[0].body)
    : yamldecode("nodes: {}")
  )

  state_decoded = (
    local.has_state
    ? yamldecode(data.aws_s3_object.state[0].body)
    : yamldecode("nodes: {}")
  )

  talos_state_decoded = (
    local.has_talos_state
    ? yamldecode(data.aws_s3_object.talos_state[0].body)
    : yamldecode("nodes: {}")
  )

  machine_configs_decoded = (
    local.has_machine_configs
    ? yamldecode(data.sops_file.machine_configs[0].raw)
    : yamldecode("nodes: {}")
  )
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
