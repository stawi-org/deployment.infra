# Omni cluster template

`main.yaml` is the canonical Omni cluster template for `stawi`. The
[`sync-cluster-template`](../../../.github/workflows/sync-cluster-template.yml)
workflow pushes it to the running Omni server on every change.

## Machine classes

The cluster spec's `ControlPlane` and `Workers` machine sets reference
machine classes named `cp` and `workers`. Both classes are declared in
[`machine-classes.yaml`](machine-classes.yaml) and applied via
`omnictl apply` by the sync workflow on every push that touches this
directory — no manual dashboard step required.

## Machine assignment

Until per-role kernel cmdline initial-labels are baked into the image
build pipeline (see `.github/workflows/regenerate-talos-images.yml`),
the operator labels each registered machine in Omni:

```sh
omnictl machine update <machine-id> --label role=cp        # CP nodes
omnictl machine update <machine-id> --label role=worker    # workers
```

Machines auto-join the matching set on the next reconcile.
