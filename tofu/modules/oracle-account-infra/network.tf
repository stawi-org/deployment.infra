# tofu/modules/oracle-account-infra/network.tf
resource "oci_core_vcn" "this" {
  compartment_id                   = var.compartment_ocid
  cidr_blocks                      = [var.vcn_cidr]
  display_name                     = "cluster-vcn-${var.account_key}"
  is_ipv6enabled                   = var.enable_ipv6
  is_oracle_gua_allocation_enabled = var.enable_ipv6
  # dns_label on the VCN is a precondition for subnets that set their own
  # dns_label (we set "privnet" on the private subnet). Without this, the
  # subnet create 400s with "Dns not enabled for Vcn". 1-15 alphanumerics.
  dns_label = "cluster"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-igw-${var.account_key}"
  enabled        = true
}

# NAT gateway removed — the cluster uses a public subnet with IGW
# egress. A NAT gateway would only matter if we added a parallel
# private subnet for workers that shouldn't be reachable, but that's
# speculative right now. Always-free egress through the IGW is free
# for the public-subnet nodes; OCI's always-free tier includes up to
# 10 TB/mo of outbound.

# Public route table: every egress goes out the IGW. OCI always-free
# includes ephemeral public IPv4s on running instances + /56 IPv6, so we
# don't need a NAT gateway. Nodes are reachable from the internet on
# Talos API (50000), Kubernetes API (6443), and whatever the LB
# forwards — same shape as the Contabo CPs.
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-rt-public-${var.account_key}"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-sl-public-${var.account_key}"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol         = "all"
      destination      = "::/0"
      destination_type = "CIDR_BLOCK"
    }
  }

  # KubeSpan WireGuard UDP 51820 from anywhere (hole-punching)
  ingress_security_rules {
    protocol = "17" # UDP
    source   = "0.0.0.0/0"
    udp_options {
      min = 51820
      max = 51820
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol    = "17" # UDP
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      udp_options {
        min = 51820
        max = 51820
      }
    }
  }
  # Talos API 50000 from anywhere — node has a public IP now and we drive
  # machine_configuration_apply straight to it from CI. Auth is the Talos
  # client cert; the open port is safe.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 50000
      max = 50000
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol    = "6"
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      tcp_options {
        min = 50000
        max = 50000
      }
    }
  }
  # Kubernetes API 6443 from anywhere (so kubectl against cp-N.<zone> works).
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      protocol    = "6"
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }
  # Kubelet 10250 from within VCN (metrics, exec, logs between cluster members).
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr
    tcp_options {
      min = 10250
      max = 10250
    }
  }
  # Etcd 2379-2380 from within VCN.
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr
    tcp_options {
      min = 2379
      max = 2380
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  # Second /24 (10.x.2.0/24) instead of the first — switching the
  # private-subnet-at-10.x.1.0/24 to a public-subnet-at-10.x.1.0/24
  # kept racing because OCI hadn't fully reaped the old subnet before
  # the new one came up. Using a different block sidesteps the
  # "CIDR overlaps" 400 during the replace apply.
  cidr_block     = cidrsubnet(var.vcn_cidr, 8, 2)
  ipv6cidr_block = var.enable_ipv6 ? cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 2) : null
  display_name   = "cluster-subnet-public-${var.account_key}"
  # Public subnet: CPs and LB-labelled nodes need to be reachable from
  # the internet on 6443/50000, and OCI always-free covers ephemeral
  # public IPv4s + GUA IPv6 at no charge. prohibit_internet_ingress
  # blocks BOTH v4 and v6 inbound from the IGW when true — flip both
  # to false so the IGW actually routes traffic.
  prohibit_internet_ingress  = false
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  dns_label                  = "pubnet"
}
