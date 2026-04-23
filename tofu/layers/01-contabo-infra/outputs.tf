# tofu/layers/01-contabo-infra/outputs.tf
output "nodes" {
  description = "Map of all Contabo-hosted nodes with the cross-layer contract shape."
  value       = { for k, m in module.nodes : k => m.node }
}

output "cp_endpoint_fqdn" {
  description = <<-EOT
    The canonical shared control-plane DNS name.
    Derived from the first entry in var.cp_dns_zones (by convention,
    the primary zone). Use as the cluster_endpoint in the form
    https://<fqdn>:6443.
  EOT
  value       = "${var.cp_dns_zones[0].label}.${var.cp_dns_zones[0].zone}"
}

output "cp_cert_sans" {
  description = <<-EOT
    DNS names that should appear in the apiserver + talosd cert SAN lists.
    Every Cloudflare-managed record across every zone in cp_dns_zones
    (shared + indexed where applicable) plus any externally-resolved
    names in var.extra_cert_sans. Node IPs are NOT included: Talos adds
    each node's bound IPs to its own certs automatically, and our
    clients (including off-prem workers joining via KubeSpan) always
    address the cluster by DNS.
  EOT
  value = concat(
    flatten([
      for z in var.cp_dns_zones : [
        for r in keys(module.cp_dns[z.zone].records) : module.cp_dns[z.zone].records[r]
      ]
    ]),
    var.extra_cert_sans,
  )
}
