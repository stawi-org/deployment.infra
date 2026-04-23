# tofu/modules/node-oracle/variables.tf
variable "name" { type = string }
variable "role" {
  type    = string
  default = "worker"
}
variable "shape" { type = string }
variable "ocpus" { type = number }
variable "memory_gb" { type = number }
variable "subnet_id" { type = string }
variable "image_id" { type = string }
variable "compartment_ocid" { type = string }
variable "availability_domain" { type = string }
variable "user_data" {
  type        = string
  sensitive   = true
  description = "Base64-encoded Talos machine config."
}
variable "bastion_id" { type = string }
variable "account_key" { type = string }
variable "region" { type = string }
