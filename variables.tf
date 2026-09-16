variable "enterprise" {
  description = "Enterprise slug, e.g. \"acme\"."
  type        = string
}

variable "api_base_url" {
  description = <<-EOT
    API base URL. For GitHub Enterprise Cloud with data residency this is
    https://api.<subdomain>.ghe.com -- NOT https://api.github.com.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://", var.api_base_url))
    error_message = "api_base_url must start with https://."
  }
}

variable "github_token" {
  description = <<-EOT
    Token with enterprise billing read/write. Strongly prefer an installation
    access token from a GitHub App installed on the enterprise over a personal
    access token, so the automation is service-owned and survives leavers.
  EOT
  type        = string
  sensitive   = true
}

variable "api_version" {
  description = "Value for the X-GitHub-Api-Version header. Pin deliberately."
  type        = string
  default     = "2022-11-28"
}

variable "budget_entity_ref" {
  description = <<-EOT
    Whether budgets scoped to a cost center reference it by "name" or "id".

    Default is "id" because the API is ASYMMETRIC and this was confirmed
    against a live enterprise:

      POST with budget_entity_name = "<cost center name>"  -> 404
        "The specified cost center or resource was not found"
      POST with budget_entity_name = "<cost center GUID>"  -> 200

    but the subsequent GET reads the value back as the NAME, not the id.
    That mismatch is permanent phantom drift, which is why
    budget_entity_name is in ignore_changes_to on the budget resource.

    Leave this on "id" unless your tenant proves otherwise.
  EOT
  type        = string
  default     = "id"

  validation {
    condition     = contains(["name", "id"], var.budget_entity_ref)
    error_message = "budget_entity_ref must be either \"name\" or \"id\"."
  }
}

variable "cost_centers" {
  description = <<-EOT
    Cost centers, keyed by a stable logical key. Keep this map as the single
    source of truth: when native provider support lands (PR #3482) the
    migration becomes a contained state-move exercise rather than a rewrite.

    Prefer enterprise_teams over users -- team membership stays in sync
    automatically as people join and leave.
  EOT

  type = map(object({
    name             = string
    organizations    = optional(list(string), [])
    repositories     = optional(list(string), [])
    users            = optional(list(string), [])
    enterprise_teams = optional(list(string), [])
  }))

  default = {}
}

variable "budgets" {
  description = <<-EOT
    Budgets, keyed by a stable logical key.

    Set cost_center to a key from var.cost_centers to scope a budget to that
    cost center; the reference is resolved automatically. Otherwise set
    entity_name explicitly.

    Note: budgets overlap across scopes and the MOST RESTRICTIVE one wins, so
    a stale enterprise-level budget can block a team before its own limit is
    reached. Note also that all teams inside one cost center share a single
    budget -- separate limits require separate cost centers.
  EOT

  type = map(object({
    scope       = string
    cost_center = optional(string)
    entity_name = optional(string)
    user        = optional(string)

    budget_type = string
    product_sku = string
    amount      = number

    prevent_further_usage = optional(bool, true)
    alert                 = optional(bool, true)
    alert_recipients      = optional(list(string), [])
    expires_at            = optional(string)
  }))

  default = {}

  validation {
    condition = alltrue([
      for b in var.budgets : contains([
        "enterprise", "organization", "repository", "cost_center",
        "multi_user_customer", "multi_user_cost_center", "user",
      ], b.scope)
    ])
    error_message = "Each budget scope must be one of: enterprise, organization, repository, cost_center, multi_user_customer, multi_user_cost_center, user."
  }

  validation {
    condition = alltrue([
      for b in var.budgets : contains(["BundlePricing", "ProductPricing", "SkuPricing"], b.budget_type)
    ])
    error_message = "Each budget_type must be one of: BundlePricing, ProductPricing, SkuPricing."
  }

  validation {
    condition = alltrue([
      for b in var.budgets : b.user != null if b.scope == "user"
    ])
    error_message = "Budgets with scope \"user\" must also set the user field."
  }

  validation {
    condition = alltrue([
      for b in var.budgets : !(b.cost_center != null && b.entity_name != null)
    ])
    error_message = "Set either cost_center or entity_name on a budget, not both."
  }
}

variable "manage_membership" {
  description = <<-EOT
    Manage cost center membership. This uses the terracurl provider because
    the /resource endpoint is POST/DELETE rather than a declarative PUT, so it
    cannot be modelled as a restapi_object.

    Set to false if you would rather assign members through the UI or through
    enterprise team assignment and keep Terraform limited to the declarative
    resources.
  EOT
  type        = bool
  default     = true
}
