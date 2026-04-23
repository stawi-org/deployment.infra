# tofu/modules/oracle-account-infra/network.tf
resource "oci_core_vcn" "this" {
  compartment_id                   = var.compartment_ocid
  cidr_blocks                      = [var.vcn_cidr]
  display_name                     = "cluster-vcn-${var.account_key}"
  is_ipv6enabled                   = var.enable_ipv6
  is_oracle_gua_allocation_enabled = var.enable_ipv6
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-igw-${var.account_key}"
  enabled        = true
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-nat-${var.account_key}"
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-rt-private-${var.account_key}"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
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

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "cluster-sl-private-${var.account_key}"

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
  # Kubelet 10250 from within VCN
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.vcn_cidr
    tcp_options {
      min = 10250
      max = 10250
    }
  }
  # Etcd 2379-2380 from within VCN
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr
    tcp_options {
      min = 2379
      max = 2380
    }
  }
  # Talos API 50000 from within VCN (bastion lives in same VCN)
  ingress_security_rules {
    protocol = "6"
    source   = var.vcn_cidr
    tcp_options {
      min = 50000
      max = 50000
    }
  }
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 1) # first /24 within the VCN
  ipv6cidr_block             = var.enable_ipv6 ? cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 1) : null
  display_name               = "cluster-subnet-private-${var.account_key}"
  prohibit_internet_ingress  = true
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  dns_label                  = "privnet"
}
