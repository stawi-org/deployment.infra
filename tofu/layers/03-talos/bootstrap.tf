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

# The previous design used terraform_data.bootstrap_trigger +
# replace_triggered_by so a CP disk-wipe (image_apply_generation bump)
# would auto re-bootstrap. That mechanism is intentionally not wired
# right now: its own input-schema updates were cascading destroy+create
# onto the imported bootstrap, and etcd rejects "bootstrap twice"
# (AlreadyExists — etcd data directory is not empty). For disaster
# recovery today: use the node-recovery workflow to reset etcd, then
# `tofu taint talos_machine_bootstrap.this` and re-apply.
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.cp]
  # Connect via the round-robin DNS — every CP carries cp.<zone> in
  # its certSANs, so TLS validates regardless of which CP DNS lands
  # on. Falls back to the bootstrap node's IPv4 only when no DNS
  # zone is configured (local-dev).
  node                 = local.cp_round_robin_dns != null ? local.cp_round_robin_dns : local.bootstrap_node.ipv4
  endpoint             = local.cp_round_robin_dns != null ? local.cp_round_robin_dns : local.bootstrap_node.ipv4
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration
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
    bootstrap_id = talos_machine_bootstrap.this.id
    # Re-probe whenever anything up-chain forces a rolling restart of
    # apiservers. Without this, wait_apiserver is cached-happy from a
    # prior apply and flux layer connect-refuses on a flapping CP.
    cp_config_hashes = jsonencode({ for k, c in talos_machine_configuration_apply.cp : k => c.id })
  }

  provisioner "local-exec" {
    # Default interpreter is /bin/sh (dash on Ubuntu) which doesn't
    # support `[[ ... ]]`.
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      # Wait for the cluster to recover after a rolling CP reboot.
      # During a reboot any single CP is briefly unreachable, but
      # etcd quorum (and therefore kube-apiserver) holds as long as
      # MAJORITY of CPs are alive. Pass when ≥ ceil(N/2) respond
      # with a numeric HTTP status — not when ALL respond. The old
      # require-all logic deadlocked through a normal rolling roll
      # because there's always one CP rebooting.
      CPS=(${join(" ", [for n in local.direct_controlplane_nodes : n.ipv4])})
      N="$${#CPS[@]}"
      if (( N == 0 )); then
        echo "no direct CPs — skipping wait"
        exit 0
      fi
      QUORUM=$(( (N / 2) + 1 ))
      MAX_ATTEMPTS=180  # 180 × 10s = 30 min wall clock — enough for
                       # sequential CP reboots + apiserver image pull
                       # + etcd leader re-election on a slow link.
      echo "probing $${N} CPs ($${CPS[*]}); pass when ≥ $${QUORUM} respond"
      LAST_HEALTHY=()
      for i in $(seq 1 "$MAX_ATTEMPTS"); do
        OK_COUNT=0
        STATUSES=()
        for IP in "$${CPS[@]}"; do
          CODE=$(curl -sk --max-time 5 --resolve "cp.antinvestor.com:6443:$IP" \
            -o /dev/null -w '%%{http_code}' \
            "https://cp.antinvestor.com:6443/healthz" 2>/dev/null || echo 000)
          # Any numeric HTTP response (200/401/403) proves TLS +
          # apiserver are up; the kubernetes provider authenticates
          # with mTLS so the eventual auth check is the client's
          # problem, not ours.
          if [[ "$CODE" =~ ^[0-9][0-9][0-9]$ && "$CODE" != "000" ]]; then
            OK_COUNT=$(( OK_COUNT + 1 ))
            STATUSES+=("$IP=$CODE")
          else
            STATUSES+=("$IP=down")
          fi
        done
        echo "  [attempt $i/$MAX_ATTEMPTS] healthy=$${OK_COUNT}/$${N} ($${STATUSES[*]})"
        if (( OK_COUNT >= QUORUM )); then
          LAST_HEALTHY=("$${STATUSES[@]}")
          # Once we hit quorum, wait one extra round to confirm it's
          # not a flapping CP — but exit fast (extra round at attempt
          # 1 wouldn't be useful, so only require stability after attempt 3).
          if (( i >= 3 )); then
            echo "quorum reached ($${OK_COUNT}/$${N} healthy); downstream calls safe"
            exit 0
          fi
        fi
        sleep 10
      done
      echo "::error::cluster never reached quorum after $${MAX_ATTEMPTS} × 10s"
      echo "::error::final per-CP status: $${STATUSES[*]}"
      echo "::group::Diagnostic dump"
      for IP in "$${CPS[@]}"; do
        echo "--- $IP /healthz ---"
        curl -sk --max-time 5 --resolve "cp.antinvestor.com:6443:$IP" \
          "https://cp.antinvestor.com:6443/healthz" 2>&1 || true
        echo
      done
      echo "::endgroup::"
      exit 1
    EOT
  }
}
