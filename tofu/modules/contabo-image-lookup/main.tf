# tofu/modules/contabo-image-lookup/main.tf
#
# Resolves a Contabo standard-image (or custom-image) ID by name pattern,
# entirely at tofu plan/apply time via two http data sources:
#
#   1. POST /auth/realms/contabo/protocol/openid-connect/token  → access_token
#   2. GET  /v1/compute/images?size=100&standardImage=<flag>    → list of images
#
# The contabo provider's `data "contabo_image"` only looks up by exact ID,
# so name resolution lives here. No shell scripts during apply, no operator
# pinning of opaque UUIDs in tfvars — change the OS or the version, change
# the var.name_pattern, plan picks the right image automatically. Same
# OAuth2 creds the contabo provider uses (sourced from R2-backed sopsed
# inventory by the calling layer); secrets never leave CI.

data "http" "token" {
  url    = "https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token"
  method = "POST"
  request_headers = {
    "Content-Type" = "application/x-www-form-urlencoded"
    "Accept"       = "application/json"
  }
  request_body = join("&", [
    "grant_type=password",
    "client_id=${var.client_id}",
    "client_secret=${var.client_secret}",
    "username=${urlencode(var.api_user)}",
    "password=${urlencode(var.api_password)}",
  ])
  # Contabo's KeyCloak instance occasionally returns transient 401
  # invalid_grant for valid credentials — same call succeeds on
  # retry. Surface it as a real error only after exhausting the
  # backoff. 5xx + 401 are both eligible to retry; permanent bad
  # creds will exhaust attempts and fall through to the postcondition.
  retry {
    attempts     = 5
    min_delay_ms = 4000
    max_delay_ms = 30000
  }
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Contabo OAuth2 token request failed (HTTP ${self.status_code}): ${self.response_body}"
    }
  }
}

locals {
  access_token = jsondecode(data.http.token.response_body).access_token
}

data "http" "images" {
  url    = "https://api.contabo.com/v1/compute/images?size=100&standardImage=${var.standard_image}"
  method = "GET"
  request_headers = {
    Authorization = "Bearer ${local.access_token}"
    Accept        = "application/json"
    # Required by the Contabo API as an audit/correlation header. A
    # static value is fine — it's only meaningful in Contabo's
    # support tickets, not in tofu state.
    "x-request-id" = "00000000-0000-0000-0000-000000000001"
  }
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Contabo image list request failed (HTTP ${self.status_code}): ${self.response_body}"
    }
  }
}

locals {
  all_images = jsondecode(data.http.images.response_body).data
  matching = [
    for img in local.all_images :
    img if can(regex(var.name_pattern, img.name))
  ]
}

check "image_match_exists" {
  assert {
    condition = length(local.matching) > 0
    error_message = format(
      "No Contabo image matched the regex %q (standardImage=%t). Available image names: %s",
      var.name_pattern,
      var.standard_image,
      jsonencode([for img in local.all_images : img.name]),
    )
  }
}
