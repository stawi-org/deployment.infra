variable "account_key" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "vpc_cidr" {
  type    = string
  default = "10.210.0.0/16"
}
variable "nodes" {
  type = map(object({
    role         = string
    machine_type = string
    zone         = string
    boot_disk_gb = number
    preemptible  = optional(bool, true)
    labels       = optional(map(string), {})
    annotations  = optional(map(string), {})
  }))
  default = {}
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "annotations" {
  type    = map(string)
  default = {}
}
variable "local_inventory_dir" {
  type    = string
  default = "/tmp/inventory"
}
variable "force_reinstall_generation" {
  type    = number
  default = 1
}
