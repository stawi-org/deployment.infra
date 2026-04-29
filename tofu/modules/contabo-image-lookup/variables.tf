variable "name_pattern" {
  type        = string
  description = "RE2 regex matched against image names. e.g. \"^Ubuntu 24\\\\.04\". Use anchors to avoid accidental matches against beta/dev variants."
}

variable "standard_image" {
  type        = bool
  default     = true
  description = "Filter the API to standardImage=true (Contabo's stock OS catalog) vs custom-uploaded images."
}

variable "client_id" {
  type      = string
  sensitive = true
}

variable "client_secret" {
  type      = string
  sensitive = true
}

variable "api_user" {
  type      = string
  sensitive = true
}

variable "api_password" {
  type      = string
  sensitive = true
}
