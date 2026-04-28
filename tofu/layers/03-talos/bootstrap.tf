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

# NOTE: a previous import block here adopted talos_machine_bootstrap
# from a magic "machine_bootstrap" id without contacting Talos. That
# was a one-shot recovery for commit 13b5abf and outlived its purpose
# — it stuck tofu state into "bootstrapped" without verifying the
# cluster, so a freshly-wiped cluster (state cleared by cluster-reset
# + nodes back in maintenance) silently never re-bootstrapped, etcd
# stayed empty, apiserver never came up.
#
# Removed. After a state-wipe reset, tofu now correctly plans a CREATE
# for talos_machine_bootstrap.this, which calls the Bootstrap RPC and
# seeds etcd.

# Drop the legacy cluster_reinstall_marker from state without
# destroying anything. The new resource below has a different name so
# tofu treats it as a fresh create — replace_triggered_by only fires
# on REPLACEMENT of a referenced resource, not creation, so the
# bootstrap is preserved across this migration.
removed {
  from = terraform_data.cluster_reinstall_marker
  lifecycle {
    destroy = false
  }
}

# Re-fire the Bootstrap RPC when EVERY Contabo CP was just wiped.
# Layer 01's cluster_reinstall_marker (per-account: SHA1 of all
# scope=all reconstruction reinstall requests for that account) is
# folded across contabo accounts in main.tf via
# local.contabo_cluster_reinstall_marker — lexicographically-largest
# hash wins so any account flipping its marker flips this aggregate.
# When it drifts, every Contabo CP is mid-reinstall in parallel and
# etcd needs to be seeded again. Per-node (scope=selected) requests
# deliberately don't change this marker — those add a healthy node
# to a quorate cluster instead.
resource "terraform_data" "cluster_wide_reinstall_marker" {
  triggers_replace = local.contabo_cluster_reinstall_marker
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [null_resource.apply_node_config]
  # Bootstrap targets ONE specific CP (the etcd seed). Use that node's
  # per-CP DNS so TLS validates against a SAN whether the CP's IP is
  # on-NIC (Contabo) or NAT'd (OCI). Falls back to its IPv4 if no DNS
  # zone is configured.
  node                 = try(local.cp_apply_target[local.bootstrap_node_key], local.bootstrap_node.ipv4)
  endpoint             = try(local.cp_apply_target[local.bootstrap_node_key], local.bootstrap_node.ipv4)
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration

  lifecycle {
    replace_triggered_by = [terraform_data.cluster_wide_reinstall_marker]
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
    bootstrap_id   = talos_machine_bootstrap.this.id
    node_apply_ids = jsonencode({ for k, n in null_resource.apply_node_config : k => n.id })
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # Cap: 10 min. After a fresh bootstrap each CP runs through ISO
    # boot → install → reboot → kubelet pulls + starts kube-apiserver
    # static pod. Image pulls + scheduler+controller-manager warmup
    # typically takes 5-8 min from talosctl bootstrap returning. After
    # the cluster is up, idempotent runs see all CPs serving instantly
    # and exit on iteration 1.
    #
    # Pass when ≥1 CP serves /healthz (any HTTP code from a TLS
    # endpoint = apiserver up). Downstream layer 04 (flux) talks to
    # the round-robin / single-host endpoint, so one healthy CP is
    # sufficient to unblock it. The other CPs catch up shortly after.
    command = <<-EOT
      set -uo pipefail
      CPS=(${join(" ", [for n in local.direct_controlplane_nodes : n.ipv4])})
      N="$${#CPS[@]}"
      (( N == 0 )) && { echo "no CPs to wait for"; exit 0; }
      for i in $(seq 1 60); do
        OK=0; STATUSES=()
        for IP in "$${CPS[@]}"; do
          CODE=$(curl -sk --max-time 3 --resolve "cp.antinvestor.com:6443:$IP" \
            -o /dev/null -w '%%{http_code}' \
            "https://cp.antinvestor.com:6443/healthz" 2>/dev/null || echo 000)
          [[ "$CODE" =~ ^[1-5][0-9][0-9]$ ]] && { OK=$((OK+1)); STATUSES+=("$IP=$CODE"); } || STATUSES+=("$IP=down")
        done
        echo "[$i/60] healthy=$${OK}/$${N} ($${STATUSES[*]})"
        (( OK >= 1 )) && exit 0
        sleep 10
      done
      echo "::error::no apiserver reached in 10 min — final: $${STATUSES[*]}"
      exit 1
    EOT
  }
}
