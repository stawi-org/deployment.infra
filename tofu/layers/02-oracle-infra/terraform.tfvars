#
# cluster_endpoint is the Talos/Kubernetes API endpoint that nodes embed in
# their generated machine config. Uses kubernetes-controlplane-api-1's public
# IPv4 (same IP preserved across PR #9's reinstall).
cluster_endpoint = "https://cp.antinvestor.com:6443"

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. Driven through scripts/
# oci-image-create-or-find.sh, which creates with --launch-mode CUSTOM
# and the explicit --launch-options block Talos arm64 needs (UEFI_64,
# fully-paravirtualized virtio, pvEncryption). Gen<N> is the image
# display_name suffix, so bumping it makes the find-or-create probe
# miss and force a fresh CreateImage.
force_image_generation = 4
