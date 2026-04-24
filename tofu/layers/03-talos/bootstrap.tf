# tofu/layers/03-talos/bootstrap.tf

# When any CP's image_apply_generation bumps (= layer 01's ensure_image
# called Contabo's reinstall action), etcd data on that node was wiped.
# In the all-CPs-together case — which is what happens on a Talos
# version bump under the current install-flow policy — the cluster has
# no quorum left and must be re-bootstrapped. Cascading bootstrap
# off this hash forces that.
#
# Caveat: this also fires on single-CP reinstalls where we'd rather do
# an etcd-preserving rolling upgrade. That path (talosctl upgrade with
# drain/uncordon) isn't wired yet; for now we assume reinstall = full
# cluster rebuild, matching the initial-install / disaster-recovery
# workflows. Revisit when we add rolling-upgrade support.
resource "terraform_data" "bootstrap_trigger" {
  # Hash over SORTED VALUES ONLY — not the { key => value } map — so a
  # node-key rename (e.g. kubernetes-controlplane-api-1 →
  # contabo-stawi-contabo-node-1) leaves the hash untouched and doesn't
  # force replace_triggered_by on talos_machine_bootstrap. A real disk
  # wipe still bumps at least one image_apply_generation → sorted set
  # changes → re-bootstrap fires.
  input = {
    gens_hash = sha256(jsonencode(sort([
      for v in values(local.controlplane_nodes) : v.image_apply_generation
    ])))
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

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.cp]
  node                 = local.bootstrap_node.ipv4
  endpoint             = local.bootstrap_node.ipv4
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration

  lifecycle {
    replace_triggered_by = [terraform_data.bootstrap_trigger]
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
    bootstrap_id = talos_machine_bootstrap.this.id
    # Re-probe whenever anything up-chain forces a rolling restart of
    # apiservers. Without this, wait_apiserver is cached-happy from a
    # prior apply and flux layer connect-refuses on a flapping CP.
    cp_config_hashes = jsonencode({ for k, c in talos_machine_configuration_apply.cp : k => c.id })
  }

  provisioner "local-exec" {
    # Default interpreter is /bin/sh — which is dash on Ubuntu and does
    # NOT support `[[ ... ]]`. Without this override every iteration of
    # the loop fails silently on "[[: not found".
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      # Probe EACH CP's apiserver individually — hitting the shared DNS
      # name lets curl pick an already-warm CP while a different one
      # (which flux may dial next) is still rebooting. We need all 3 to
      # answer before downstream kubernetes-provider calls are safe.
      # Probe only CPs we were able to talosctl-apply (direct_controlplane_nodes
      # skips ones known to be unreachable from the runner, e.g. OCI CP during
      # the current bootstrap). Probing an unreachable IP keeps ALL_OK=false
      # indefinitely and wedges the whole run.
      CPS=(${join(" ", [for n in local.direct_controlplane_nodes : n.ipv4])})
      echo "probing apiservers on: $${CPS[*]}"
      for i in $(seq 1 90); do
        ALL_OK=true
        for IP in "$${CPS[@]}"; do
          CODE=$(curl -sk --max-time 5 --resolve "cp.antinvestor.com:6443:$IP" \
            -o /dev/null -w '%%{http_code}' \
            "https://cp.antinvestor.com:6443/healthz" 2>/dev/null || echo 000)
          # Any numeric HTTP response proves TLS termination works; 401
          # from anonymous-auth-off is fine because the kubernetes
          # provider will authenticate with the client cert.
          if [[ "$CODE" =~ ^[0-9][0-9][0-9]$ && "$CODE" != "000" ]]; then
            echo "  [attempt $i] $IP: HTTP $CODE"
          else
            echo "  [attempt $i] $IP: not ready (code=$CODE)"
            ALL_OK=false
          fi
        done
        if [[ "$ALL_OK" == "true" ]]; then
          echo "all $${#CPS[@]} apiservers responding — downstream calls safe"
          exit 0
        fi
        sleep 10
      done
      echo "not all apiservers reachable after 15 min"
      exit 1
    EOT
  }
}
