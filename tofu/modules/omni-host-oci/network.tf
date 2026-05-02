# Dedicated VCN for the omni-host. Separate from the cluster-node
# VCN (oracle-account-infra creates that one) so the omni-host's
# blast radius stays narrow and the security-list inbound surface
# stays tighter than what cluster nodes need.
resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name}-vcn"
  is_ipv6enabled = var.enable_ipv6
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

# Inbound: 80/443 (Omni UI via CF), 8090 (SideroLink API), 8100
# (k8s-proxy), 50180/UDP (SideroLink WG), 51820/UDP (admin WG).
# SSH (22) is NOT exposed — admin path is the WG VPN. Egress: all.
resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination = "::/0"
      protocol    = "all"
    }
  }

  # TCP ingress: 80, 443, 8090, 8100
  dynamic "ingress_security_rules" {
    for_each = toset(["80", "443", "8090", "8100"])
    content {
      protocol = "6" # TCP
      source   = "0.0.0.0/0"
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  # UDP ingress: 50180 (SideroLink WG), 51820 (admin WG)
  dynamic "ingress_security_rules" {
    for_each = toset(["50180", "51820"])
    content {
      protocol = "17" # UDP
      source   = "0.0.0.0/0"
      udp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  # IPv6 mirrors of the same rules (when var.enable_ipv6).
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? toset(["80", "443", "8090", "8100"]) : []
    content {
      protocol = "6"
      source   = "::/0"
      tcp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? toset(["50180", "51820"]) : []
    content {
      protocol = "17"
      source   = "::/0"
      udp_options {
        min = tonumber(ingress_security_rules.value)
        max = tonumber(ingress_security_rules.value)
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.name}-subnet"
  route_table_id             = oci_core_route_table.this.id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
  # OCI subnets MUST be /64 IPv6 CIDRs. The VCN's IPv6 block is a
  # /56 (the only size OCI allocates), so carve a /64 from it: take
  # the first 4 hextets of the /56 prefix and append "::/64". The
  # 5th hextet's high bits are zero in OCI's /56 allocations, so
  # this slice is always within the VCN block.
  ipv6cidr_blocks = var.enable_ipv6 ? [
    "${join(":", slice(split(":", split("/", oci_core_vcn.this.ipv6cidr_blocks[0])[0]), 0, 4))}::/64"
  ] : null
}

# Reserved public IPv4 — survives instance recreate. AAAA records
# point at the instance-attached IPv6 (which is stable while the
# instance lives — see spec risk table for IPv6 caveat).
resource "oci_core_public_ip" "this" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.name}-pubip"
  private_ip_id  = data.oci_core_private_ips.this.private_ips[0].id
}

# Look up the VNIC's primary private IP — needed to attach the
# reserved public IP. References oci_core_instance.this which is
# created in Task 7's main.tf — this file alone won't validate
# until that lands.
data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_vnic" "this" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "this" {
  vnic_id = data.oci_core_vnic.this.id
}
