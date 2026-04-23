output "records" {
  description = <<-EOT
    Map of record name → fully-qualified form.
    The caller passes var.zone_suffix explicitly because this module
    intentionally works off a zone_id (no zone-name lookup).
  EOT
  value = {
    for rname in keys(var.records) : rname => (
      endswith(rname, var.zone_suffix) ? rname : "${rname}.${var.zone_suffix}"
    )
  }
}
