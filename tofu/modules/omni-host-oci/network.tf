# tofu/modules/omni-host-oci/network.tf
#
# The omni-host shares the cluster VCN's public subnet (passed in via
# var.subnet_id from 00-omni-server). That VCN already announces its
# IPs reliably in BGP (the cluster CP node's IP is globally reachable
# within minutes of allocation), whereas a dedicated omni-host VCN
# spent hours stuck below 10% global propagation across multiple
# fresh /16 blocks — see the 2026-05-03 incident for the test data.
#
# Per-VNIC ports the omni-host needs (8090/8100/443/80/50180/51820)
# come from a Network Security Group attached to the omni-host's VNIC
# only. NSGs and security lists are evaluated as a UNION (any-allow
# wins), so the cluster subnet's existing seclist stays untouched and
# cluster nodes don't accidentally get those ports exposed.

resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-nsg"
}

# TCP ingress: 80, 443, 8090, 8100
resource "oci_core_network_security_group_security_rule" "tcp_ingress_v4" {
  for_each                  = toset(["80", "443", "8090", "8100"])
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "tcp_ingress_v6" {
  for_each                  = var.enable_ipv6 ? toset(["80", "443", "8090", "8100"]) : toset([])
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "::/0"
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

# UDP ingress: 50180 (SideroLink WG), 51820 (admin user-VPN)
resource "oci_core_network_security_group_security_rule" "udp_ingress_v4" {
  for_each                  = toset(["50180", "51820"])
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "CIDR_BLOCK"
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "udp_ingress_v6" {
  for_each                  = var.enable_ipv6 ? toset(["50180", "51820"]) : toset([])
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "CIDR_BLOCK"
  source                    = "::/0"
  udp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

# Egress: all (matches the cluster subnet's seclist, so the union is
# still all-egress regardless of which list is consulted).
resource "oci_core_network_security_group_security_rule" "egress_v4" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "egress_v6" {
  count                     = var.enable_ipv6 ? 1 : 0
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "::/0"
}

# IPv6 lookup — the instance attribute exposes the IPv4 directly via
# `oci_core_instance.this.public_ip`, but the assigned IPv6 address
# isn't on the resource itself. Read it from the primary VNIC.
data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_vnic" "this" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}
