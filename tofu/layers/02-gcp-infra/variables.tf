# tofu/layers/02-gcp-infra/variables.tf
variable "r2_account_id" {
  type      = string
  sensitive = true
}

variable "account_key" {
  type = string
  validation {
    condition = contains(
      try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, []),
      var.account_key,
    )
    error_message = "account_key must be listed under gcp: in accounts.yaml."
  }
}

variable "local_inventory_dir" {
  type    = string
  default = "/tmp/inventory"
}

variable "force_reinstall_generation" {
  type    = number
  default = 1
}

variable "age_recipients" {
  type = string
}
