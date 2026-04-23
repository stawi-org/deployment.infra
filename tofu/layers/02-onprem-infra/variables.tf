# tofu/layers/02-onprem-infra/variables.tf
variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}

variable "onprem_locations" {
  type = map(object({
    description     = optional(string, "")
    region          = string
    site_ipv4_cidrs = optional(list(string), [])
    site_ipv6_cidrs = optional(list(string), [])
    nodes = map(object({
      region      = optional(string)
      role        = optional(string, "worker")
      ipv4        = optional(string)
      ipv6        = optional(string)
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
    }))
  }))
  default     = {}
  description = <<-EOT
    First-class on-premises location inventory. This layer does not provision
    physical machines; it declares stable node identity, topology labels, and
    optional last-known addresses so layer 03 can generate audited Talos
    node configs. Addresses are deliberately optional because on-prem nodes
    IPs may be DHCP, SLAAC, CGNAT, or otherwise non-permanent.
  EOT

  validation {
    condition = alltrue(flatten([
      for _, loc in var.onprem_locations : [
        for _, node in loc.nodes : contains(["worker"], node.role)
      ]
    ]))
    error_message = "On-prem nodes are currently restricted to role = \"worker\". Do not stretch the Talos control plane across unmanaged WAN sites."
  }

  validation {
    condition = alltrue(flatten([
      for location_key, loc in var.onprem_locations : [
        for node_key, _ in loc.nodes :
        length("${location_key}-${node_key}") <= 63
        && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", "${location_key}-${node_key}"))
      ]
    ]))
    error_message = "On-prem location and node keys must combine into valid RFC 1123 node names, for example kampala-hq-rack-1."
  }
}
