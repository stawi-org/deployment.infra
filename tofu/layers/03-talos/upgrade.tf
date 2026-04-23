# tofu/layers/03-talos/upgrade.tf
#
# In-place Talos upgrade detection. When a node's last-applied version
# in talos-state.yaml differs from var.talos_version, run
# scripts/talos-upgrade.sh --preserve before applying config.

locals {
  # Flatten upstream_talos_state (keyed by account) into a per-node map.
  upstream_talos_state_by_node = merge([
    for acct_key, node_map in local.upstream_talos_state : node_map
  ]...)

  # Nodes whose last-applied Talos version differs from target.
  # Excludes nodes with no recorded last_applied (first-apply path).
  upgrade_needed = {
    for k, v in local.all_nodes_from_state : k => v
    if try(local.upstream_talos_state_by_node[k].last_applied_version, "") != "" &&
    local.upstream_talos_state_by_node[k].last_applied_version != var.talos_version
  }
}

# Write the talosconfig to a temp file so talosctl can read it.
resource "local_sensitive_file" "talosconfig" {
  filename = "${path.root}/.talosconfig"
  content  = data.talos_client_configuration.this.talos_config
}

resource "null_resource" "talos_upgrade" {
  for_each = local.upgrade_needed

  triggers = {
    from_version = local.upstream_talos_state_by_node[each.key].last_applied_version
    to_version   = var.talos_version
    schematic_id = talos_image_factory_schematic.this.id
    node_ipv4    = try(each.value.ipv4, "")
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      NODE           = try(each.value.ipv4, "")
      TALOSCONFIG    = local_sensitive_file.talosconfig.filename
      IMAGE          = data.talos_image_factory_urls.this.urls.installer
      EXPECT_VERSION = var.talos_version
    }
    command = "${path.root}/../../scripts/talos-upgrade.sh"
  }
}
