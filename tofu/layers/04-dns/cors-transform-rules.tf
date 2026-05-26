# tofu/layers/04-dns/cors-transform-rules.tf
#
# Cloudflare Response Header Transform Rules — adds CORS headers to
# ALL responses from oauth2.stawi.org, including Cloudflare's own error
# pages (521/522/523). This is the single source of truth for CORS on
# public OAuth2/OIDC endpoints.
#
# When Cloudflare can't reach the origin, its error page normally lacks
# CORS headers, causing browsers to report a misleading CORS error
# instead of the actual network error. This rule ensures CORS headers
# are present on every response.
#
# OIDC endpoints are public by spec, so Access-Control-Allow-Origin: *
# is correct. Using * also means no origin allowlist to maintain as new
# frontend domains are added.

resource "cloudflare_ruleset" "oauth2_cors_headers" {
  zone_id = "706bf604a333d866bb38c03bf643e79a" # stawi.org
  kind    = "zone"
  name    = "CORS headers for oauth2.stawi.org"
  phase   = "http_response_headers_transform"

  rules = [
    {
      action = "rewrite"
      action_parameters = {
        headers = [
          {
            name      = "Access-Control-Allow-Origin"
            operation = "set"
            value     = "*"
          },
          {
            name      = "Access-Control-Allow-Methods"
            operation = "set"
            value     = "GET, POST, OPTIONS"
          },
          {
            name      = "Access-Control-Allow-Headers"
            operation = "set"
            value     = "Authorization, Content-Type, Accept"
          },
          {
            name      = "Access-Control-Max-Age"
            operation = "set"
            value     = "86400"
          },
        ]
      }
      expression  = "(http.host eq \"oauth2.stawi.org\")"
      description = "Add CORS * to all oauth2.stawi.org responses (inc. CF error pages)"
      enabled     = true
    },
  ]
}
