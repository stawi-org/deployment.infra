# Omni cluster template

`main.yaml` is the canonical Omni cluster template for `stawi`. The
[`sync-cluster-template`](../../../.github/workflows/sync-cluster-template.yml)
workflow pushes it to the running Omni server on every change.

## One-time operator setup: machine classes

The cluster spec's `ControlPlane` and `Workers` machine sets reference
two machine classes by name (`cp` and `workers`). Until the cluster
template format for `MachineClass` resources is figured out, the
operator creates these manually:

1. Open <https://cp.stawi.org/omni> → **MachineClasses** → **Create
   MachineClass**.
2. Class name: `cp`. Match labels: `role=cp`. Save.
3. Class name: `workers`. Match labels: `role=worker`. Save.

Or via `omnictl` once the YAML format is verified — `omnictl apply`
currently fails parsing `MachineClassSpec` ("illegal base64 data at
input byte 6") regardless of the field-name spelling, so the
dashboard is the working path.

After the classes exist in Omni, the next push to `main` touching
`tofu/shared/clusters/**` will sync the cluster template; the
`ControlPlane` / `Workers` references resolve against the
dashboard-created classes.

## Machine assignment

Until per-role kernel cmdline initial-labels are baked into the image
build pipeline (see `.github/workflows/regenerate-talos-images.yml`),
the operator labels each registered machine in Omni:

```sh
omnictl machine update <machine-id> --label role=cp        # CP nodes
omnictl machine update <machine-id> --label role=worker    # workers
```

Machines auto-join the matching set on the next reconcile.
