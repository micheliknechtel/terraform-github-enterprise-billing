output "cost_center_ids" {
  description = "Cost center IDs keyed by logical key. Keep this for the future state migration to native provider resources."
  value       = { for k, cc in restapi_object.cost_center : k => cc.id }
}

output "budget_ids" {
  description = "Budget IDs keyed by logical key."
  value       = { for k, b in restapi_object.budget : k => b.id }
}

output "reassigned_resources" {
  description = <<-EOT
    Raw membership API responses. A non-empty "reassigned_resources" array
    means a resource was TAKEN from another cost center. Treat that as a
    signal in CI -- it is silent in the GitHub UI.
  EOT
  value       = { for k, m in terracurl_request.membership : k => m.response }
}
