age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Gen<N> is the image
# display_name suffix; bumping triggers replace_triggered_by on
# oci_core_image.talos and forces a new CreateImage on the next
# apply. launchOptions are pinned via image_metadata.json embedded
# in the .oci archive the workflow builds (see "Stage Talos .oci
# archive" step in tofu-layer.yml) — OCI auto-detects the archive
# on import and reads externalLaunchOptions as the image's defaults.
# Bumped 9 → 10 alongside the schema-fix landing: the gen9 image
# in each tenancy was created by the previous CLI-driven flow from
# a plain qcow2 (no metadata) and boots with the wrong defaults.
force_image_generation = 10

# Per-node reinstalls are now driven by request files under
# .github/reconstruction/. The tofu-reconstruct workflow opens a PR
# adding reinstall-*.yaml; merging fires cluster-reinstall.yml which
# dispatches tofu-apply, and the request hash flows into the per-node
# terraform_data.reinstall_marker triggers via reconstruction.tf.
