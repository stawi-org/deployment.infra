# tofu/layers/02-oci-storage/terraform.tfvars
#
# bwire operator user name — used by oci-operator-csk.tf to look up
# the existing admin user and mint a CSK against it.
oci_operator_user_name = "bwire@stawi.org"

# alimbacho67 operator user name — same role in the alimbacho67
# tenancy (separate from bwire). The CSK minted against this user
# is what OpenObserve uses to write to the telemetry-storage
# bucket living in alimbacho67.
# Per the tenancy's user list (surfaced by the check block when the
# initial guess didn't match): `cluster-provisioner` and
# `alimbacho67@gmail.com` are the only two users. Use the human
# operator email — cluster-provisioner is the WIF-bound one used by
# tofu apply and shouldn't carry long-lived CSKs.
alimbacho_operator_user_name = "alimbacho67@gmail.com"
