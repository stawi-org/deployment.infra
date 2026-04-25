# tofu/layers/03-talos/node-roles.tf
#
# Apply node-role.kubernetes.io/<role>= labels via kubectl after the
# apiserver is up. Talos's machine.nodeLabels validation rejects
# labels under the protected `node-role.kubernetes.io/` prefix
# (https://github.com/siderolabs/talos/issues/7355), so the
# `derived_labels.node-role.kubernetes.io/worker = ""` we emit from
# the node modules is silently dropped during config-apply. Talos
# auto-applies `node-role.kubernetes.io/control-plane=` for control-
# plane nodes, but workers come up with ROLES=<none> in
# `kubectl get nodes`.
#
# Workaround: post-bootstrap, write the cluster kubeconfig to a temp
# file and run `kubectl label` for each node whose role we know from
# inventory. --overwrite keeps it idempotent on repeat applies.

resource "null_resource" "node_role_labels" {
  depends_on = [null_resource.wait_apiserver]

  triggers = {
    # Re-run when the set of roles changes — adding a worker, promoting
    # to controlplane, etc. Map[node]→role keyed string is the smallest
    # signal that captures intent.
    role_map = jsonencode({
      for k, v in local.all_nodes_from_state : k => try(v.role, "")
    })
    bootstrap_id = talos_machine_bootstrap.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KUBECONFIG_RAW = data.talos_cluster_kubeconfig.this.kubeconfig_raw
      WORKER_NODES   = join(" ", [for k, _ in local.worker_nodes : k])
      CP_NODES       = join(" ", [for k, _ in local.controlplane_nodes : k])
    }
    command = <<-EOT
      set -euo pipefail
      kc=$(mktemp); chmod 600 "$kc"
      printf '%s' "$KUBECONFIG_RAW" > "$kc"
      trap 'rm -f "$kc"' EXIT
      command -v kubectl >/dev/null || {
        curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/v1.35.2/bin/linux/amd64/kubectl"
        sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
      }
      for n in $WORKER_NODES; do
        echo "labelling $n as worker"
        kubectl --kubeconfig "$kc" label node "$n" \
          node-role.kubernetes.io/worker= --overwrite || \
          echo "::warning::failed to label $n (not yet joined?)"
      done
      # control-plane label is auto-applied by Talos, but re-asserting
      # is a no-op and catches edge cases (Talos' kube-controller-mgr
      # restart races, etc.).
      for n in $CP_NODES; do
        kubectl --kubeconfig "$kc" label node "$n" \
          node-role.kubernetes.io/control-plane= --overwrite || \
          echo "::warning::failed to label CP $n"
      done
    EOT
  }
}
