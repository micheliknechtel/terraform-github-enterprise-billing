# GitHub Enterprise billing as code — interim module

Terraform module for managing **cost centers** and **budgets** in GitHub
Enterprise Cloud while native provider support is still in review.

This is a **bridge, not a destination.** See [Migration path](#migration-path).

## Why this exists

The GitHub Terraform provider does not yet ship resources for enterprise
billing. Native support for cost centers is in active review as
[integrations/terraform-provider-github#3482][pr3482] (4 resources, 2 data
sources), assigned to the **v6.14.0** milestone. Budgets are not covered by
that PR and remain an open request, [#2739][issue2739], with no assignee.

The REST API, however, is **generally available** with full CRUD for both.
This module wraps those endpoints so you get real Terraform state, plan/apply
and drift detection — rather than shell scripts in a pipeline.

## Status of this module

Validated with `terraform validate`, and applied end to end against a live
GitHub Enterprise Cloud tenant: cost center and budget creation, a rename via
`PATCH`, membership assignment, and the drift checks described below. The
findings in [Four findings that shape this module](#four-findings-that-shape-this-module)
are empirical, not derived from documentation.

Before you trust it in production, run it against a throwaway cost center and
confirm the two items under [Verify first](#verify-first).

> **Disclaimer.** This is personal, unofficial work. It is not a GitHub
> product, is not supported by GitHub, and carries no warranty. It depends on
> community Terraform providers (`Mastercard/restapi`, `devops-rob/terracurl`)
> that have not been vetted by GitHub — review them against your own supply
> chain policy before use. Licensed under MIT.

## Requirements

| Component | Version | Why |
|---|---|---|
| Terraform | >= 1.3.0 | `optional()` in object type constraints |
| `Mastercard/restapi` | **>= 3.0** | `ignore_server_additions` does not exist in 2.x |
| `devops-rob/terracurl` | >= 2.0 | Explicit destroy for the membership endpoint |

Both providers are **community-maintained and not supported by GitHub.** They
will need to clear your third-party dependency review.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

export TF_VAR_github_token="$(your-app-token-command)"
terraform init
terraform plan
```

```hcl
cost_centers = {
  platform = {
    name             = "ACME-Platform"
    enterprise_teams = ["acme-platform-engineering"]
  }
}

budgets = {
  platform_copilot = {
    scope       = "cost_center"
    cost_center = "platform"
    budget_type = "SkuPricing"
    product_sku = "copilot_ai_credit"
    amount      = 1000

    prevent_further_usage = true
    alert                 = true
    alert_recipients      = ["finops"]
  }
}
```

### Data residency

`api_base_url` must be `https://api.<subdomain>.ghe.com`, **not**
`https://api.github.com`.

### Authentication

Use an **installation access token from a GitHub App installed on the
enterprise** with write access to enterprise billing. A personal access token
works but ties the automation to an individual and breaks when they leave. A
custom enterprise role with fine-grained billing write is an alternative.

## Verify first

Two things to confirm against a throwaway cost center before rolling out:

1. **`budget_entity_ref`.** The REST docs describe `budget_entity_name` as
   "the name of the entity", so this module defaults to `"name"`. If your
   tenant rejects that for cost-center-scoped budgets, set
   `budget_entity_ref = "id"`. This is the most likely cause of a 400/422 on
   first apply.
2. **The budget create/read shape.** `POST /budgets` returns the object
   wrapped as `{"message", "budget": {...}}`, while `GET /budgets/{id}`
   returns it unwrapped. The module handles the create side with
   `id_attribute = "budget/id"`; confirm the read reconciles cleanly rather
   than producing a permanent diff.

## Non-obvious details this module handles

These are the things that break a naive implementation.

| Behaviour | Handling |
|---|---|
| `restapi` defaults to `PUT`; GitHub requires `PATCH` | `update_method = "PATCH"` on the provider |
| `PATCH` on a cost center returns **422 `object is missing required key: name`** if `name` is omitted | `name` is always present in the payload |
| API returns `state` and `resources` that are not in the payload | `ignore_server_additions = true` |
| `consumed_amount` reflects live spend and changes on its own | `ignore_changes_to = ["consumed_amount"]` |
| `POST /budgets` nests the id one level down | `id_attribute = "budget/id"` |
| `terracurl` defaults `skip_destroy = true`, silently orphaning membership | `skip_destroy = false` |
| Scope and SKU cannot change in place | `force_new` forces recreation |

## Known limitations

- **Membership has no drift detection.** `POST|DELETE /resource` is an
  imperative add/remove pair, not a declarative `PUT`, so it cannot be a
  `restapi_object`. The `terracurl` create response does not match the shape
  of `GET /cost-centers/{id}`, so enabling read would plan a replace on every
  run. **Mitigation: assign `enterprise_teams` instead of individual `users`
  and let GitHub keep membership in sync.** The `membership_is_intact` check
  block catches the total-loss case — see below.

- **Silent reassignment.** A resource belongs to exactly **one** cost center.
  Adding it to a second one silently takes it from the first; the previous
  owner is reported in `reassigned_resources`. Treat a non-empty value in the
  `reassigned_resources` output as a CI signal.

  **This was observed live, not theorised.** Re-running `plan` a few hours
  after a clean apply reported `No changes` while the managed cost center had
  in fact gone to `"resources": []` — the user had been added to another cost
  center in the UI and was dropped from this one without any signal. The
  `membership_is_intact` check block now catches it: the cost center's
  `api_data` *is* refreshed on read, so "membership configured but the API
  reports none" is detectable even though the membership resource itself is
  unreadable. It warns rather than fails, because the remediation
  (`-replace` on the membership) takes the member *back* from wherever it went,
  which is not always what you want.

- **Budgets overlap and the most restrictive wins.** A stale enterprise-level
  budget can block a team before its own cost center limit is reached.

- **One budget per cost center.** Teams sharing a cost center share its
  budget. Separate limits require separate cost centers.

- **Untyped payloads.** Bodies are `jsonencode`d, so the provider cannot
  type-check fields. Errors surface at apply time, not plan time. The variable
  validations in `variables.tf` catch the common cases earlier.

- **No `import` support.** See below.

## Migration path

When [#3482][pr3482] lands, cost centers gain native resources:

```
github_enterprise_cost_center
github_enterprise_cost_center_organizations
github_enterprise_cost_center_repositories
github_enterprise_cost_center_users
```
plus data sources `github_enterprise_cost_center` / `_cost_centers`.

That PR **replaces both** the `restapi_object.cost_center` and the
`terracurl_request.membership` resources here — including membership, natively.
Budgets will still need this module until #2739 is picked up.

Because there is no `import` path today, migration means `terraform state rm`
followed by `import` into the new resource types. **This module keeps every
cost center name and ID in a single map** (`var.cost_centers`, and the
`cost_center_ids` output) precisely so that migration is a contained,
scriptable exercise rather than a rewrite. Do not scatter these identifiers.

## Links

- PR — native cost center support: <https://github.com/integrations/terraform-provider-github/pull/3482>
- Issue — budgets request: <https://github.com/integrations/terraform-provider-github/issues/2739>
- REST — cost centers: <https://docs.github.com/en/enterprise-cloud@latest/rest/billing/cost-centers>
- REST — budgets: <https://docs.github.com/en/enterprise-cloud@latest/rest/billing/budgets>
- Control and track costs: <https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-and-track-costs>
- Enterprise teams: <https://docs.github.com/en/enterprise-cloud@latest/admin/managing-accounts-and-repositories/managing-users-in-your-enterprise/create-enterprise-teams>
- `Mastercard/restapi`: <https://registry.terraform.io/providers/Mastercard/restapi/latest/docs/resources/object>
- `devops-rob/terracurl`: <https://registry.terraform.io/providers/devops-rob/terracurl/latest/docs/resources/request>

[pr3482]: https://github.com/integrations/terraform-provider-github/pull/3482
[issue2739]: https://github.com/integrations/terraform-provider-github/issues/2739

---

## Verified against a live enterprise

Every statement below was tested against a real GitHub Enterprise Cloud tenant,
not inferred from documentation. All 28 enterprise billing operations in the
OpenAPI spec were exercised.

### Spec location

The enterprise billing endpoints are **absent from `api.github.com.json`**.
They exist only in the GHEC spec:

```
https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/ghec/ghec.json
```

If you generate a client from the wrong spec, these endpoints simply will not
be there.

### Four findings that shape this module

**1. `PUT` returns 404, not 405.**
The `restapi` provider defaults to `PUT` for updates. The cost center endpoint
only accepts `PATCH`, and rejects `PUT` with *"Not Found"* — which sends you
hunting for a bad ID instead of a bad verb. `update_method = "PATCH"` in
`versions.tf` is non-negotiable.

A `PATCH` that omits `name` returns `422 "Invalid input: data matches no
possible input"`. `name` is effectively mandatory on every update.

**2. `budget_entity_name` is asymmetric.**
For `budget_scope = "cost_center"` you must **write the GUID** — writing the
name returns `404 "The specified cost center or resource was not found"`. But
the API **reads the value back as the name**. That mismatch is permanent
phantom drift, hence `budget_entity_ref = "id"` plus
`ignore_changes_to = ["budget_entity_name"]`.

**3. Cost center DELETE is a SOFT delete. Budget DELETE is HARD.**

| | after DELETE |
|---|---|
| cost center | `200`, `state: "deleted"`, readable indefinitely |
| budget | `404` |

Because `state` is not part of the request payload, the provider will never
plan a change for it. A cost center deleted in the UI stays silently
"managed". The `check "cost_centers_are_active"` block in `main.tf` exists
solely to surface this. Names **can** be reused after a soft delete — a new
GUID is issued.

**4. `GET /cost-centers` can return duplicate rows.**
Observed with a single raw `curl`, with no `Link` header present, so this is
not pagination: **88 rows returned for 72 unique IDs**. The duplicate rows
carry `name: ""`. Multiplicity varied — one ID appeared 6 times. `GET /{id}`
returned correct data in every case.

> **Do not build anything that looks up a cost center by name.**
> Key off the ID. Deduplicate by ID and prefer the row with a non-empty name.

### Other confirmed behaviours

- One budget per `scope + entity + sku`. A second returns `409 "A budget with
  this scope already exists"`.
- `budget_scope = "user"` rejects `copilot_ai_credit`:
  `400 ... Must be one of: premium_requests`.
- `POST /{id}/resource` with an unknown key returns `400 "No resources to
  add"`; with a non-member user, `403 "These users are not part of
  enterprise"`. Neither is a hard failure, so check the response body.
- Undocumented response fields: cost centers return `ai_credit_pool_enabled`,
  budgets return `budget_thresholds`. Both are handled by
  `ignore_server_additions = true` — no explicit ignore entry needed.
- `GET /budgets` is paginated at 10 per page. Use `--paginate`; a naive first
  page makes the list look unstable when it is not.

---

## scripts/inventory.sh

A read-only audit of the cost centers and budgets in an enterprise.

```bash
./scripts/inventory.sh <enterprise-slug> [name-prefix]
```

It exists mainly to demonstrate the two list-endpoint workarounds in a form you
can reuse:

- **cost centers** are deduplicated by ID, preferring the row with a non-empty
  name, so the counts it prints are the real ones rather than the inflated
  figure the API (and the web UI) report;
- **budgets** are read with `--paginate`, because the endpoint returns 10 per
  page. Reading only the first page makes the list look unstable when it is not.

For data residency tenants, point `gh` at your subdomain first:

```bash
export GH_HOST=<subdomain>.ghe.com
```
