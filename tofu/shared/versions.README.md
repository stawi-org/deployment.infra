# tofu/shared/versions.auto.tfvars.json

Single source of truth for Talos, Kubernetes, and FluxCD versions
across the whole repo.

## Why JSON, not HCL

OpenTofu auto-loads any `*.auto.tfvars` *or* `*.auto.tfvars.json` in
the working directory. JSON wins here because workflow runners parse
it with `jq` (already on every GitHub-Actions Ubuntu image) instead
of needing an HCL parser to grep a version out for `talosctl` install
steps and similar.

## Consumers

- **Tofu**: each layer under `tofu/layers/*/` has a relative symlink
  `versions.auto.tfvars.json -> ../../shared/versions.auto.tfvars.json`.
  Tofu picks the values up automatically via the auto-loaded tfvars
  file mechanism.
- **GitHub workflows**: parse with `jq -r '.talos_version'` against
  the file path. See `.github/workflows/tofu-layer.yml` (talosctl
  install) and `.github/workflows/talos-diagnose.yml`.

## Bumping a version

1. Edit one field in `versions.auto.tfvars.json`.
2. Open a PR. Merge.
3. Re-run `tofu-apply.yml`. Talos in-place upgrade fires for Contabo
   nodes (talosctl upgrade --image, no disk wipe). OCI currently
   destroy+creates because `image_id` is in the OCI reinstall marker
   triggers — flatten that separately if a fully in-place upgrade
   matters for OCI.

## Don't add explanatory keys to the JSON file

Tofu's auto-tfvars treats every key as a variable assignment. An
unrecognised key like `_comment` triggers "Value for undeclared
variable" on every plan. Keep prose here, in this README.
