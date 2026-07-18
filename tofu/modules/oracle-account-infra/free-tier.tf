# tofu/modules/oracle-account-infra/free-tier.tf
#
# Guardrails for OCI Ampere A1 fleet + Always Free block volume.
#
# Fleet compute targets (intentional; may bill after monthly free hours):
#   worker:       4 OCPU + 24 GB
#   controlplane: 2 OCPU + 12 GB
#   ≤2 A1 instances, shape VM.Standard.A1.Flex only
#
# Always Free block volume (hard — never exceed free envelope):
#   Oracle cap: 200 GB total boot+data per tenancy
#   Operational buffer: 4 GB so we never land on the ceiling
#   Usable boot total enforced here: 196 GB
#
# Continuous free A1 compute is 2 OCPU + 12 GB. When
# enforce_always_free=true, plan also fails if tenancy totals exceed that
# continuous free compute envelope. Fleet default is false so workers can
# be 4/24 as inventory policy requires.
#
# Official Always Free (home region), as of 2026-06-15 docs:
#   https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

locals {
  free_tier_default_boot_gb = 196
  free_tier_boot_buffer_gb  = 4
  free_tier_boot_hard_gb    = 200
  free_tier_boot_usable_gb  = local.free_tier_boot_hard_gb - local.free_tier_boot_buffer_gb

  # sum([]) is invalid in OpenTofu — guard empty node maps (empty account).
  free_tier_ocpus_total = length(var.nodes) == 0 ? 0 : sum([
    for _, n in var.nodes : n.ocpus
  ])
  free_tier_memory_total = length(var.nodes) == 0 ? 0 : sum([
    for _, n in var.nodes : n.memory_gb
  ])
  free_tier_boot_total = length(var.nodes) == 0 ? 0 : sum([
    for _, n in var.nodes : coalesce(n.boot_volume_size_gb, local.free_tier_default_boot_gb)
  ])
  free_tier_node_count = length(var.nodes)

  free_tier_non_a1 = [
    for k, n in var.nodes : k
    if n.shape != "VM.Standard.A1.Flex"
  ]
}

check "always_free_shape_is_a1_flex" {
  assert {
    condition     = length(local.free_tier_non_a1) == 0
    error_message = <<-EOT
      account ${var.account_key}: fleet only allows shape VM.Standard.A1.Flex.
      Non-A1 nodes: ${join(", ", local.free_tier_non_a1)}.
    EOT
  }
}

check "always_free_instance_count" {
  assert {
    condition     = local.free_tier_node_count <= 2
    error_message = <<-EOT
      account ${var.account_key}: ${local.free_tier_node_count} A1 instances declared;
      fleet policy allows at most 2 Ampere A1 VMs per tenancy.
    EOT
  }
}

check "always_free_ocpu_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_ocpus_total <= 2
    error_message = <<-EOT
      account ${var.account_key}: sum(ocpus)=${local.free_tier_ocpus_total} exceeds continuous
      Always Free Ampere A1 cap of 2 OCPU (1,500 OCPU-hours/month).
      Set enforce_always_free=false for intentional paid A1 hours (fleet workers are 4/24),
      or resize nodes.yaml so tenancy totals ≤ 2 OCPU.
    EOT
  }
}

check "always_free_memory_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_memory_total <= 12
    error_message = <<-EOT
      account ${var.account_key}: sum(memory_gb)=${local.free_tier_memory_total} exceeds continuous
      Always Free Ampere A1 cap of 12 GB (9,000 GB-hours/month).
      Set enforce_always_free=false for intentional paid A1 hours, or resize nodes.yaml.
    EOT
  }
}

# Boot volume: ALWAYS enforced with 4 GB buffer under the 200 GB free cap,
# regardless of enforce_always_free. Never provision into the free ceiling.
check "always_free_block_volume_cap" {
  assert {
    condition     = local.free_tier_boot_total <= local.free_tier_boot_usable_gb
    error_message = <<-EOT
      account ${var.account_key}: sum(boot_volume_size_gb)=${local.free_tier_boot_total} exceeds
      usable Always Free Block Volume budget of ${local.free_tier_boot_usable_gb} GB
      (${local.free_tier_boot_hard_gb} hard cap − ${local.free_tier_boot_buffer_gb} GB buffer).
      Set boot_volume_size_gb per node so the sum is ≤ ${local.free_tier_boot_usable_gb}.
    EOT
  }
}

check "always_free_per_node_minimums" {
  assert {
    condition = alltrue([
      for _, n in var.nodes :
      n.ocpus >= 1 && n.memory_gb >= 6 && coalesce(n.boot_volume_size_gb, local.free_tier_default_boot_gb) >= 50
    ])
    error_message = <<-EOT
      account ${var.account_key}: each A1 node needs ocpus >= 1, memory_gb >= 6
      (Oracle A1 flex floor for usable Talos/Ubuntu), boot_volume_size_gb >= 50
      (Talos QCOW2 floor). Check nodes.yaml for undersized entries.
    EOT
  }
}

# Fleet role ceilings (always on): worker ≤4/24, controlplane ≤2/12
check "fleet_role_size_ceilings" {
  assert {
    condition = alltrue([
      for _, n in var.nodes :
      n.role == "controlplane"
      ? (n.ocpus <= 2 && n.memory_gb <= 12)
      : (n.ocpus <= 4 && n.memory_gb <= 24)
    ])
    error_message = <<-EOT
      account ${var.account_key}: node exceeds fleet role ceiling
      (controlplane ≤ 2 OCPU / 12 GB, worker ≤ 4 OCPU / 24 GB).
    EOT
  }
}
