output "image_id" {
  description = "Contabo image UUID matching var.name_pattern. Plan-time error if no image matches."
  value       = local.matching[0].imageId
}

output "image_name" {
  description = "Resolved image's display name — useful for log breadcrumbs."
  value       = local.matching[0].name
}
