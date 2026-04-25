# tofu/layers/03-talos/bootstrap.tf

# Drop the stale terraform_data.bootstrap_trigger from state without
# deleting any external resource (terraform_data has none). Removed
# because its input schema changes were cascading replace_triggered_by
# onto talos_machine_bootstrap and re-bootstrapping an already-joined
# cluster. See the block above talos_machine_bootstrap below for the
# follow-up plan. One-shot — safe to delete after a successful apply.
removed {
  from = terraform_data.bootstrap_trigger
  lifecycle {
    destroy = false
  }
}

# Import block: adopts the existing bootstrap into tofu state without
# contacting Talos. Required because commit 13b5abf's OCI rename
# changed bootstrap_trigger.input keys, which fired replace_triggered_by
# and destroyed talos_machine_bootstrap.this from state. The cluster is
# still bootstrapped (etcd data present on api-1) — this just puts
# tofu's tracking record back. After the first apply following this
# commit, the block is a no-op.
import {
  to = talos_machine_bootstrap.this
  id = "machine_bootstrap"
}

# Re-fire the Bootstrap RPC when ALL Contabo CPs were just wiped.
# Layer 01's force_reinstall_generation is the cluster-wide reinstall
# counter — bumping it re-images every Contabo CP in parallel and
# leaves etcd empty on every CP. After that, Talos's Bootstrap RPC
# must fire again to seed etcd. Per-node reinstalls
# (per_node_force_reinstall_generation) deliberately don't bump this
# output — they add a healthy node to a quorate cluster instead.
resource "terraform_data" "cluster_reinstall_marker" {
  triggers_replace = data.terraform_remote_state.contabo.outputs.cluster_reinstall_generation
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.cp]
  # Connect via the round-robin DNS — every CP carries cp.<zone> in
  # its certSANs, so TLS validates regardless of which CP DNS lands
  # on. Falls back to the bootstrap node's IPv4 only when no DNS
  # zone is configured (local-dev).
  node                 = local.cp_round_robin_dns != null ? local.cp_round_robin_dns : local.bootstrap_node.ipv4
  endpoint             = local.cp_round_robin_dns != null ? local.cp_round_robin_dns : local.bootstrap_node.ipv4
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration

  lifecycle {
    replace_triggered_by = [terraform_data.cluster_reinstall_marker]
  }
}

# Wait for kube-apiserver /healthz before this layer reports success.
# talos_machine_bootstrap returns the moment etcd starts; kube-apiserver
# as a static pod takes another 60-180s to finish pulling + starting.
# Without this wait the downstream 04-flux layer connect-refuses on
# 6443. This is the Ansible role's "validate apiserver ready" step,
# reimplemented as a Terraform-native probe.
#
# talos_cluster_health can't be used here — it additionally blocks on
# kubelet CSR approval (handled by kubelet-serving-cert-approver, which
# needs CNI, which needs Flux = circular wait).
resource "null_resource" "wait_apiserver" {
  depends_on = [talos_machine_bootstrap.this]

  triggers = {
    bootstrap_id     = talos_machine_bootstrap.this.id
    cp_config_hashes = jsonencode({ for k, c in talos_machine_configuration_apply.cp : k => c.id })
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # Cap: 5 min. Steady-state applies don't reboot anything (apply_mode
    # = auto), bootstrap is a one-shot, image pulls are seconds. If
    # we're still waiting after 5 min something is actually wrong —
    # exit and surface the per-CP status rather than hide a flapping
    # cluster behind a 30-min timer.
    command = <<-EOT
      set -uo pipefail
      CPS=(${join(" ", [for n in local.direct_controlplane_nodes : n.ipv4])})
      N="$${#CPS[@]}"
      (( N == 0 )) && { echo "no CPs to wait for"; exit 0; }
      QUORUM=$(( (N / 2) + 1 ))
      for i in $(seq 1 30); do
        OK=0; STATUSES=()
        for IP in "$${CPS[@]}"; do
          CODE=$(curl -sk --max-time 3 --resolve "cp.antinvestor.com:6443:$IP" \
            -o /dev/null -w '%%{http_code}' \
            "https://cp.antinvestor.com:6443/healthz" 2>/dev/null || echo 000)
          [[ "$CODE" =~ ^[1-5][0-9][0-9]$ ]] && { OK=$((OK+1)); STATUSES+=("$IP=$CODE"); } || STATUSES+=("$IP=down")
        done
        echo "[$i/30] healthy=$${OK}/$${N} ($${STATUSES[*]})"
        (( OK >= QUORUM )) && exit 0
        sleep 10
      done
      echo "::error::quorum not reached in 5 min — final: $${STATUSES[*]}"
      exit 1
    EOT
  }
}
