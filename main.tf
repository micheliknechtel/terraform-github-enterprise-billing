locals {
  api_headers = {
    Authorization          = "Bearer ${var.github_token}"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = var.api_version
  }

  cost_center_path = "/enterprises/${var.enterprise}/settings/billing/cost-centers"
  budget_path      = "/enterprises/${var.enterprise}/settings/billing/budgets"

  # Membership payloads, omitting empty lists so we never POST an empty array.
  membership = {
    for k, cc in var.cost_centers : k => {
      for field, members in {
        users            = cc.users
        organizations    = cc.organizations
        repositories     = cc.repositories
        enterprise_teams = cc.enterprise_teams
      } : field => members if length(members) > 0
    }
  }

  # Only create a membership request where there is actually something to assign.
  membership_to_manage = var.manage_membership ? {
    for k, payload in local.membership : k => payload if length(payload) > 0
  } : {}

  # Resolve a cost-center-scoped budget to the reference form the API expects.
  budget_entity_names = {
    for k, b in var.budgets : k => (
      b.cost_center != null
      ? (
        var.budget_entity_ref == "id"
        ? restapi_object.cost_center[b.cost_center].id
        : var.cost_centers[b.cost_center].name
      )
      : coalesce(b.entity_name, "")
    )
  }

  # Build each budget body, dropping nulls so we never send a null field.
  budget_bodies = {
    for k, b in var.budgets : k => {
      for field, value in {
        budget_scope          = b.scope
        budget_entity_name    = local.budget_entity_names[k]
        budget_type           = b.budget_type
        budget_product_sku    = b.product_sku
        budget_amount         = b.amount
        prevent_further_usage = b.prevent_further_usage
        user                  = b.user
        expires_at            = b.expires_at
        budget_alerting = {
          will_alert       = b.alert
          alert_recipients = b.alert_recipients
        }
      } : field => value if value != null
    }
  }
}

###############################################################################
# Cost centers
#
# POST   /cost-centers            -> {"id", "name", "state", "resources"}
# GET    /cost-centers/{id}
# PATCH  /cost-centers/{id}       -> ALWAYS send "name", even when unchanged.
#                                    Omitting it returns
#                                    422 "object is missing required key: name".
# DELETE /cost-centers/{id}
###############################################################################

resource "restapi_object" "cost_center" {
  for_each = var.cost_centers

  path         = local.cost_center_path
  id_attribute = "id"

  # The API returns "state" and "resources", which are not in our payload.
  # Without this, Terraform tries to revert them and the resource is recreated.
  ignore_server_additions = true

  # "resources" is managed by the membership resource below, not here.
  #
  # "state" is deliberately NOT listed. DELETE on a cost center is a SOFT
  # delete: the object keeps returning 200 with state="deleted" forever.
  # Masking that field would make an out-of-band deletion invisible and
  # Terraform would keep reporting "No changes" for a dead resource.
  # The check block at the bottom of this file surfaces it instead.
  ignore_changes_to = ["resources"]

  data = jsonencode({
    name = each.value.name
  })
}

###############################################################################
# Cost center membership
#
# POST   /cost-centers/{id}/resource   {users|organizations|repositories|enterprise_teams}
# DELETE /cost-centers/{id}/resource   same body shape
#
# This is an imperative add/remove pair rather than a declarative PUT, so it
# cannot be a restapi_object. terracurl models it with an explicit destroy.
#
# WARNING: a resource belongs to exactly ONE cost center. Adding it to a second
# one SILENTLY REASSIGNS it, and the previous owner is reported in the
# response under "reassigned_resources". Inspect the output after apply.
###############################################################################

resource "terracurl_request" "membership" {
  for_each = local.membership_to_manage

  name   = "cost-center-membership-${each.key}"
  method = "POST"
  url    = "${var.api_base_url}${local.cost_center_path}/${restapi_object.cost_center[each.key].id}/resource"

  headers        = local.api_headers
  request_body   = jsonencode(each.value)
  response_codes = ["200"]

  destroy_method         = "DELETE"
  destroy_url            = "${var.api_base_url}${local.cost_center_path}/${restapi_object.cost_center[each.key].id}/resource"
  destroy_headers        = local.api_headers
  destroy_request_body   = jsonencode(each.value)
  destroy_response_codes = ["200"]

  # CRITICAL: terracurl defaults skip_destroy to true, which would silently
  # skip the DELETE and orphan membership on destroy.
  skip_destroy = false

  # No drift detection on membership: the create response is
  # {message, reassigned_resources}, which does not match the shape returned
  # by GET /cost-centers/{id}. Enabling read here would compare mismatched
  # documents and plan a replace on every run. Reconcile membership out of
  # band, or prefer enterprise_teams so GitHub keeps it in sync for you.
  skip_read = true

  max_retry      = 3
  retry_interval = 5
}

###############################################################################
# Budgets
#
# POST   /budgets              -> {"message", "budget": {"id", ...}}  (wrapped)
# GET    /budgets/{id}         -> budget object                       (unwrapped)
# PATCH  /budgets/{id}
# DELETE /budgets/{id}
#
# The create response nests the id one level down, hence id_attribute below.
###############################################################################

resource "restapi_object" "budget" {
  for_each = var.budgets

  path         = local.budget_path
  id_attribute = "budget/id"

  ignore_server_additions = true

  # consumed_amount reflects live spend and changes on its own. Without this,
  # every plan reports drift and the governance story falls apart.
  ignore_changes_to = ["consumed_amount", "budget_entity_name"]

  # These cannot be changed in place; changing them must recreate the budget.
  force_new = ["budget_scope", "budget_type", "budget_product_sku"]

  data = jsonencode(local.budget_bodies[each.key])

  depends_on = [restapi_object.cost_center]
}

###############################################################################
# Soft-delete detection
#
# DELETE /cost-centers/{id} returns 200 but does NOT remove the object: a
# subsequent GET still returns 200 with state="deleted". (Budgets differ --
# their DELETE is a hard delete and the next GET is a clean 404.)
#
# Because "state" is not part of the request payload, the provider will never
# plan a change for it, so a cost center deleted in the UI or by a rogue curl
# would silently stay "managed" in state forever.
#
# This check runs on every plan and apply and turns that silence into a
# visible warning. It intentionally does NOT fail the run -- the remediation
# is a targeted taint/replace, not a hard stop on unrelated changes.
###############################################################################

check "cost_centers_are_active" {
  assert {
    condition = alltrue([
      for k, cc in restapi_object.cost_center :
      lookup(cc.api_data, "state", "active") != "deleted"
    ])
    error_message = join(" ", [
      "One or more managed cost centers were deleted outside Terraform.",
      "GitHub soft-deletes cost centers, so the API still answers 200 and",
      "no drift is planned. Deleted:",
      join(", ", [
        for k, cc in restapi_object.cost_center :
        "${k} (${lookup(cc.api_data, "name", "?")})"
        if lookup(cc.api_data, "state", "active") == "deleted"
      ]),
      "-- run: terraform apply -replace='restapi_object.cost_center[\"<key>\"]'",
    ])
  }
}

###############################################################################
# Drift guard: membership lost to a silent reassignment
#
# A resource (user, org, repo, team) can belong to only ONE cost center at a
# time. Adding it to a second cost center -- via the UI, another Terraform
# workspace, or a stray curl -- silently removes it from the first. The API
# returns 200 and the losing cost center is never notified.
#
# Terraform cannot see this on its own: membership is managed by a
# terracurl_request with skip_read = true (its create response is not
# comparable to a GET), and "resources" is in ignore_changes_to on the cost
# center. So the plan stays clean while the membership is gone.
#
# The cost center's api_data IS refreshed on read, though, so we can catch the
# unambiguous case: we asked for members, and the API now reports none.
#
# Observed live on 2026-09-16: a user managed here was added to another cost
# center in the UI and was dropped from this one. "terraform plan" reported
# "No changes" while resources had gone to [].
###############################################################################

check "membership_is_intact" {
  assert {
    condition = alltrue([
      for k, _ in local.membership_to_manage :
      trimspace(lookup(restapi_object.cost_center[k].api_data, "resources", "[]")) != "[]"
    ])
    error_message = join(" ", [
      "Membership is configured for one or more cost centers but the API",
      "reports no members. A resource can belong to only one cost center, so",
      "this usually means it was reassigned elsewhere and silently removed",
      "here. Affected:",
      join(", ", [
        for k, _ in local.membership_to_manage :
        "${k} (${lookup(restapi_object.cost_center[k].api_data, "name", "?")})"
        if trimspace(lookup(restapi_object.cost_center[k].api_data, "resources", "[]")) == "[]"
      ]),
      "-- check where the member went, then re-apply with:",
      "terraform apply -replace='terracurl_request.membership[\"<key>\"]'",
      "(note this will take the member back, removing it from the other cost center)",
    ])
  }
}
