variable "cloudflare_zone_id" {
  description = "The Cloudflare zone ID that contains news.byte-cave.com."
  type        = string
}

locals {
  opml_feed_expression      = "(http.host eq \"news.byte-cave.com\" and http.request.uri.path eq \"/feeds/news.opml\")"
  news_subdomain_expression = "(http.host eq \"news.byte-cave.com\")"
}

resource "cloudflare_ruleset" "opml_feed_cache" {
  zone_id     = var.cloudflare_zone_id
  name        = "OPML feed cache"
  description = "Cache only the public OPML feed."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [{
    ref         = "cache_public_opml_feed"
    description = "Cache the public OPML feed for one day without query strings."
    expression  = local.opml_feed_expression
    action      = "set_cache_settings"

    action_parameters = {
      cache = true
      edge_ttl = {
        mode    = "override_origin"
        default = 86400
      }
      browser_ttl = {
        mode = "respect_origin"
      }
      cache_key = {
        custom_key = {
          query_string = {
            exclude = {
              all = true
            }
          }
        }
      }
    }
  }]
}

resource "cloudflare_ruleset" "news_subdomain_rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "News subdomain rate limit"
  description = "Rate-limit all requests to news.byte-cave.com."
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    ref         = "rate_limit_news_subdomain"
    description = "Block an IP after 60 news subdomain requests in one minute."
    expression  = local.news_subdomain_expression
    action      = "block"
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 60
      requests_per_period = 60
      mitigation_timeout  = 60
    }
  }]
}
