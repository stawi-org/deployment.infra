# tofu/modules/oracle-account-infra/free-tier.tf
#
# Always Free continuous A1 + block volume guardrails.
#
# Continuous free Ampere A1 (post 2026-06-15, per tenancy):
#   2 OCPU + 12 GB memory total (1,500 OCPU-hours + 9,000 GB-hours / month)
#   ≤2 A1 instances, shape VM.Standard.A1.Flex only
#
# Always Free block volume:
#   Oracle cap: 200 GB total boot+data
#   Operational buffer: 4 GB → usable 196 GB
#
# enforce_always_free=true (fleet default): fail plan on continuous free
# compute overage. Block buffer is always enforced.
#
# Official docs:
#   https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

locals {
  free_tier_default_boot_gb = 196
  free_tier_boot_buffer_gb  = 4
  free_tier_boot_hard_gb    = 200
  free_tier_boot_usable_gb  = local.free_tier_boot_hard_gb - local.free_tier_boot_buffer_gb

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
      account ${var.account_key}: Always Free only allows shape VM.Standard.A1.Flex.
      Non-A1 nodes: ${join(", ", local.free_tier_non_a1)}.
    EOT
  }
}

check "always_free_instance_count" {
  assert {
    condition     = local.free_tier_node_count <= 2
    error_message = <<-EOT
      account ${var.account_key}: ${local.free_tier_node_count} A1 instances declared;
      Always Free allows at most 2 Ampere A1 VMs per tenancy.
    EOT
  }
}

check "always_free_ocpu_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_ocpus_total <= 2
    error_message = <<-EOT
      account ${var.account_key}: sum(ocpus)=${local.free_tier_ocpus_total} exceeds continuous
      Always Free Ampere A1 cap of 2 OCPU (1,500 OCPU-hours/month).
      Resize nodes.yaml: one 2/12 node, or two 1/6 nodes.
    EOT
  }
}

check "always_free_memory_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_memory_total <= 12
    error_message = <<-EOT
      account ${var.account_key}: sum(memory_gb)=${local.free_tier_memory_total} exceeds continuous
      Always Free Ampere A1 cap of 12 GB (9,000 GB-hours/month).
      Resize nodes.yaml: one 2/12 node, or two 1/6 nodes.
    EOT
  }
}

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
      (Oracle A1 flex floor), boot_volume_size_gb >= 50 (Talos QCOW2 floor).
    EOT
  }
}

# Per-node must not exceed continuous free pool alone.
check "always_free_per_node_ceilings" {
  assert {
    condition = alltrue([
      for _, n in var.nodes :
      n.ocpus <= 2 && n.memory_gb <= 12
    ])
    error_message = <<-EOT
      account ${var.account_key}: each node must be ≤ 2 OCPU / 12 GB
      (continuous Always Free pool). Prefer solo 2/12 or two 1/6.
    EOT
  }
}
