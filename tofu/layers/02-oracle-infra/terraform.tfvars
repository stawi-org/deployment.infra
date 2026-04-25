age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Gen<N> is the image
# display_name suffix; bumping it forces a new CreateImage and
# replaces the in-state image. The CLI script behind data.external
# pins launchOptions to UEFI_64 + fully-paravirtualized virtio at
# image-create time (the only API path for that — see
# scripts/oci-image-create-or-find.sh).
force_image_generation = 9

# Per-node reinstalls are now driven by request files under
# .github/reconstruction/. The tofu-reconstruct workflow opens a PR
# adding reinstall-*.yaml; merging fires cluster-reinstall.yml which
# dispatches tofu-apply, and the request hash flows into the per-node
# terraform_data.reinstall_marker triggers via reconstruction.tf.
