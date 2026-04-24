#
# cluster_endpoint is the Talos/Kubernetes API endpoint that nodes embed in
# their generated machine config. Uses kubernetes-controlplane-api-1's public
# IPv4 (same IP preserved across PR #9's reinstall).
cluster_endpoint = "https://cp.antinvestor.com:6443"

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump to force a fresh OCI custom image. The image created on the
# first successful CreateImage (run 24878434603) is being rejected by
# LaunchInstance as "Invalid image" — most likely the imported QCOW2
# ended up in a faulted state that doesn't surface in the AVAILABLE
# probe. Bumping this changes the image display_name, the existing-
# image probe returns empty, and a fresh image is created from the
# now-stable Object Storage object.
force_image_generation = 2
