variable "provider_name" {
  type        = string
  description = "Provider kind: contabo | oracle | onprem. 'provider' is reserved, hence the _name suffix."
  validation {
    condition     = contains(["contabo", "oracle", "onprem"], var.provider_name)
    error_message = "provider_name must be one of: contabo, oracle, onprem."
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
  type    = bool
  default = false
}
variable "write_nodes" {
  type    = bool
  default = false
}
variable "write_state" {
  type    = bool
  default = false
}
variable "write_talos_state" {
  type    = bool
  default = false
}
variable "write_machine_configs" {
  type    = bool
  default = false
}

variable "auth_content" {
  type    = any
  default = null
}
variable "nodes_content" {
  type    = any
  default = null
}
variable "state_content" {
  type    = any
  default = null
}
variable "talos_state_content" {
  type    = any
  default = null
}
variable "machine_configs_content" {
  type    = any
  default = null
}
