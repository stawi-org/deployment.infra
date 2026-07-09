# tofu/modules/oracle-account-infra/free-tier.tf
#
# Plan-time Always Free caps for OCI Ampere A1 + block volume.
#
# Official Always Free (home region), as of 2026-06-15 docs:
#   https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
#
#   Compute A1.Flex: 1,500 OCPU-hours + 9,000 GB-hours / month
#     → continuous equivalent: 2 OCPU + 12 GB memory total per tenancy
#     → at most two A1 instances sharing that pool
#   Block Volume:    200 GB total (boot + data volumes combined)
#   Object Storage:  20 GB total (not enforced here — managed outside
#                    this module's instance map)
#
# Pre-2026-06 tenancies were commonly documented as 4 OCPU / 24 GB.
# Inventory and module defaults previously targeted that older cap.
# These checks fail plan if a tenancy would exceed the current free
# envelope so apply never quietly creates billable A1 capacity.
#
# Override (paid tenancy only): set enforce_always_free = false on the
# module call from 02-oracle-infra. Default is true.

locals {
  free_tier_default_boot_gb = 100

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
    condition     = !var.enforce_always_free || length(local.free_tier_non_a1) == 0
    error_message = <<-EOT
      account ${var.account_key}: Always Free mode only allows shape VM.Standard.A1.Flex.
      Non-A1 nodes: ${join(", ", local.free_tier_non_a1)}.
      Set enforce_always_free=false only for intentionally paid tenancies.
    EOT
  }
}

check "always_free_instance_count" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_node_count <= 2
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
      account ${var.account_key}: sum(ocpus)=${local.free_tier_ocpus_total} exceeds Always Free
      Ampere A1 cap of 2 OCPU continuous (1,500 OCPU-hours/month).
      Resize nodes.yaml so tenancy totals ≤ 2 OCPU (e.g. one 2/12 node, or two 1/6 nodes).
    EOT
  }
}

check "always_free_memory_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_memory_total <= 12
    error_message = <<-EOT
      account ${var.account_key}: sum(memory_gb)=${local.free_tier_memory_total} exceeds Always Free
      Ampere A1 cap of 12 GB continuous (9,000 GB-hours/month).
      Resize nodes.yaml so tenancy totals ≤ 12 GB memory.
    EOT
  }
}

check "always_free_block_volume_cap" {
  assert {
    condition     = !var.enforce_always_free || local.free_tier_boot_total <= 200
    error_message = <<-EOT
      account ${var.account_key}: sum(boot_volume_size_gb)=${local.free_tier_boot_total} exceeds
      Always Free Block Volume cap of 200 GB (boot + data combined).
      Set boot_volume_size_gb per node so the sum is ≤ 200 (default per node is now ${local.free_tier_default_boot_gb}).
    EOT
  }
}

check "always_free_per_node_minimums" {
  assert {
    condition = !var.enforce_always_free || alltrue([
      for _, n in var.nodes :
      n.ocpus >= 1 && n.memory_gb >= 6 && coalesce(n.boot_volume_size_gb, local.free_tier_default_boot_gb) >= 50
    ])
    error_message = <<-EOT
      account ${var.account_key}: each Always Free A1 node needs ocpus >= 1, memory_gb >= 6
      (Oracle A1 flex floor for usable Talos/Ubuntu), boot_volume_size_gb >= 50
      (Talos QCOW2 floor). Check nodes.yaml for undersized entries.
    EOT
  }
}
