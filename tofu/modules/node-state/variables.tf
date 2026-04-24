variable "provider_name" {
  type        = string
  description = "Provider kind: contabo | oracle | onprem. 'provider' is reserved, hence the _name suffix."
  validation {
    condition     = contains(["contabo", "oracle", "onprem"], var.provider_name)
    error_message = "Invalid provider_name \"${var.provider_name}\". Must be one of: contabo, oracle, onprem."
  }
}

variable "account" {
  type        = string
  description = "Account key. For on-prem this is the location key (e.g. savannah-hq)."
}

variable "bucket" {
  type        = string
  default     = "cluster-tofu-state"
  description = "R2 bucket holding the inventory tree."
}

variable "key_prefix" {
  type        = string
  default     = "production/inventory"
  description = "Key prefix under which inventory/<provider>/<account>/*.yaml live."
}

variable "age_recipients" {
  type        = list(string)
  description = "Age public keys to encrypt writes to. Reads use SOPS_AGE_KEY from env."
}

# ---- Write flags + content ----------------------------------------------
# The agreed R2 inventory layout is only:
#   <provider>/<account>/auth.yaml
#   <provider>/<account>/nodes.yaml
#   <provider>/<account>/<talos-version>/<node-name>.yaml
# No state.yaml / talos-state.yaml / machine-configs.yaml — those were
# transitional. Provider observed state lives in tfstate and crosses
# layers via terraform_remote_state outputs instead.

variable "write_auth" {
  type        = bool
  default     = false
  description = "Set true to write auth.yaml to R2. Requires auth_content to be non-null. Contabo auth is age-encrypted; Oracle is plaintext."
}
variable "write_nodes" {
  type        = bool
  default     = false
  description = "Set true to write nodes.yaml to R2. Requires nodes_content to be non-null. Plaintext (declared intent — not sensitive)."
}
variable "write_per_node_configs" {
  type        = bool
  default     = false
  description = "Set true to write <talos_version>/<node>.yaml for every entry in per_node_configs_content. Each value is a full Talos machine config rendered for that node."
}

variable "auth_content" {
  type        = any
  default     = null
  description = "YAML-shaped map written to auth.yaml when write_auth = true. Ignored on read-only invocations."
}
variable "nodes_content" {
  type        = any
  default     = null
  description = "YAML-shaped map written to nodes.yaml when write_nodes = true. Ignored on read-only invocations."
}
variable "per_node_configs_content" {
  type        = map(string)
  default     = {}
  description = "Per-node Talos machine config, keyed by node_key. Each value is the RAW multi-document YAML string (as emitted by data.talos_machine_configuration.*.machine_configuration) written verbatim to <talos_version>/<node_key>.yaml when write_per_node_configs = true."
}
variable "talos_version" {
  type        = string
  default     = ""
  description = "Talos version used as the subdirectory name under <account>/ for per-node configs. Required when write_per_node_configs = true."
}

variable "local_inventory_dir" {
  type        = string
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Reads use this; writes go directly to R2."
}
