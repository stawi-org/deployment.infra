# tofu/layers/02-onprem-infra/terraform.tfvars
#
# This default keeps the layer safe to apply before any on-prem sites are
# declared. Production inventory should normally live in the canonical R2
# object at production/config/cluster-inventory.yaml. This tfvars file is only
# a local fallback.
#
# Shape:
# onprem_locations = {
#   kampala-hq = {
#     region          = "UG"
#     site_ipv4_cidrs = ["192.0.2.0/24"]
#     site_ipv6_cidrs = ["2001:db8:10::/64"]
#     nodes = {
#       rack-1 = {} # IPs are optional; on-prem workers may not have stable addresses.
#     }
#   }
# }
onprem_locations = {}
