# tofu/layers/03-talos/apply_oracle.tf
locals {
  oci_nodes = { for k, v in local.all_nodes : k => v if v.provider == "oracle" }
  # Stable forwarded-port assignment: 50001 + sorted-index. Idempotent across applies.
  oci_node_port_map = { for i, k in sort(keys(local.oci_nodes)) : k => 50001 + i }
}

resource "null_resource" "bastion_tunnel" {
  for_each = local.oci_nodes

  triggers = {
    # Re-run when the session ID changes (ttl expiry → layer 02 re-plans a new session).
    session_id = data.terraform_remote_state.oracle.outputs.bastion_sessions[each.key].session_id
    port       = local.oci_node_port_map[each.key]
    node_ip    = data.terraform_remote_state.oracle.outputs.bastion_sessions[each.key].target_ip
    node_key   = each.key # carried in triggers so the destroy provisioner can reference it
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      BASTION_KEY_PEM = data.terraform_remote_state.oracle.outputs.bastion_session_keys[each.key]
      SESSION_ID      = data.terraform_remote_state.oracle.outputs.bastion_sessions[each.key].session_id
      BASTION_REGION  = data.terraform_remote_state.oracle.outputs.bastion_sessions[each.key].bastion_region
      TARGET_IP       = data.terraform_remote_state.oracle.outputs.bastion_sessions[each.key].target_ip
      LOCAL_PORT      = tostring(local.oci_node_port_map[each.key])
      NODE_KEY        = each.key
    }
    # HCL heredoc: $$ escapes a literal $ so the shell (not HCL) expands the variable.
    command = <<-EOT
      set -euo pipefail
      KEY_FILE="/tmp/bastion-$${NODE_KEY}.key"
      PID_FILE="/tmp/bastion-$${NODE_KEY}.pid"
      LOG_FILE="/tmp/bastion-$${NODE_KEY}.log"

      # Kill any stale tunnel before starting a new one
      if [ -f "$${PID_FILE}" ] && kill -0 "$(cat $${PID_FILE})" 2>/dev/null ; then
        kill "$(cat $${PID_FILE})" || true
      fi

      # Write the PEM with umask 077 so the file is never world- or group-readable
      # even for the instant between creation and chmod. Belt and suspenders: chmod after.
      (umask 077 ; printf '%s' "$${BASTION_KEY_PEM}" > "$${KEY_FILE}")
      chmod 0600 "$${KEY_FILE}"

      BASTION_HOST="host.bastion.$${BASTION_REGION}.oci.oraclecloud.com"

      nohup ssh -i "$${KEY_FILE}" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
          -N -L "$${LOCAL_PORT}:$${TARGET_IP}:50000" \
          -p 22 \
          "$${SESSION_ID}@$${BASTION_HOST}" \
          > "$${LOG_FILE}" 2>&1 &
      echo $! > "$${PID_FILE}"

      # Wait up to 60s for the tunnel to be accepting connections.
      for i in $(seq 1 30); do
        if bash -c "echo > /dev/tcp/127.0.0.1/$${LOCAL_PORT}" 2>/dev/null; then
          echo "Tunnel to $${NODE_KEY} ready on port $${LOCAL_PORT}"
          exit 0
        fi
        sleep 2
      done
      echo "Tunnel to $${NODE_KEY} failed to open; see $${LOG_FILE}" >&2
      cat "$${LOG_FILE}" >&2 || true
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = {
      NODE_KEY = self.triggers.node_key
    }
    command = <<-EOT
      PID_FILE="/tmp/bastion-$${NODE_KEY}.pid"
      if [ -f "$${PID_FILE}" ] && kill -0 "$(cat $${PID_FILE})" 2>/dev/null; then
        kill "$(cat $${PID_FILE})" || true
      fi
      rm -f "/tmp/bastion-$${NODE_KEY}.pid" "/tmp/bastion-$${NODE_KEY}.log" "/tmp/bastion-$${NODE_KEY}.key" || true
    EOT
  }
}

resource "terraform_data" "oci_config_hash" {
  for_each = local.oci_nodes
  input = {
    config     = each.value.role == "controlplane" ? data.talos_machine_configuration.cp[each.key].machine_configuration : data.talos_machine_configuration.worker[each.key].machine_configuration
    generation = var.force_talos_reapply_generation
    # Mirrors the cp_config_hash behavior — see apply.tf for rationale.
    image_apply_generation = each.value.image_apply_generation
  }
}

resource "talos_machine_configuration_apply" "oci" {
  for_each                    = local.oci_nodes
  depends_on                  = [null_resource.bastion_tunnel]
  client_configuration        = data.terraform_remote_state.secrets.outputs.client_configuration
  machine_configuration_input = each.value.role == "controlplane" ? data.talos_machine_configuration.cp[each.key].machine_configuration : data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = "127.0.0.1:${local.oci_node_port_map[each.key]}"
  endpoint                    = "127.0.0.1:${local.oci_node_port_map[each.key]}"
  # See apply.tf for the rationale on "reboot" — ensures kubelet restarts on
  # every machine config change.
  apply_mode = "reboot"

  lifecycle {
    replace_triggered_by = [terraform_data.oci_config_hash[each.key]]
  }
}
