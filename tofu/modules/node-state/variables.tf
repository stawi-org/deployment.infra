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
variable "write_state" {
  type        = bool
  default     = false
  description = "Set true to write state.yaml to R2. Requires state_content to be non-null. Plaintext observed provider state (instance IDs, IPs)."
}
variable "write_talos_state" {
  type        = bool
  default     = false
  description = "Set true to write talos-state.yaml to R2. Requires talos_state_content to be non-null. Plaintext observed Talos state (version, hash)."
}
variable "write_machine_configs" {
  type        = bool
  default     = false
  description = "Set true to write machine-configs.yaml to R2. Requires machine_configs_content to be non-null. Age-encrypted (contains cluster PKI)."
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
variable "state_content" {
  type        = any
  default     = null
  description = "YAML-shaped map written to state.yaml when write_state = true. Ignored on read-only invocations."
}
variable "talos_state_content" {
  type        = any
  default     = null
  description = "YAML-shaped map written to talos-state.yaml when write_talos_state = true. Ignored on read-only invocations."
}
variable "machine_configs_content" {
  type        = any
  default     = null
  description = "YAML-shaped map written to machine-configs.yaml when write_machine_configs = true. Ignored on read-only invocations."
}

variable "local_inventory_dir" {
  type        = string
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Reads use this; writes go directly to R2."
}
