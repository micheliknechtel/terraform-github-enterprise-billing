terraform {
  required_version = ">= 1.3.0"

  required_providers {
    # v3.x is REQUIRED: ignore_server_additions does not exist in v2.x.
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 2.0"
    }
  }
}

provider "restapi" {
  uri = var.api_base_url

  # GitHub returns the created object on POST.
  create_returns_object = true

  # CRITICAL: the provider defaults to PUT. GitHub's billing endpoints only
  # accept PATCH for updates -- without this, every update fails.
  update_method = "PATCH"

  headers = local.api_headers

  # GitHub applies secondary rate limits to write-heavy API use.
  rate_limit = 5
}

provider "terracurl" {}
