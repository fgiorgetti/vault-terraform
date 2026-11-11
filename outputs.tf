output "vault_namespace" {
  value       = kubernetes_namespace.vault.metadata[0].name
  description = "The Kubernetes namespace where Vault is installed."
}

output "unseal_strategy" {
  value       = var.unseal_type
  description = "The configured auto-unseal mechanism."
}

output "unsealer_image" {
  value       = var.unsealer_image
  description = "Applied container image for sidecar auto-unsealer."
}

output "injector_image_tag" {
  value       = var.injector_image_tag
  description = "Applied Vault Agent Injector UBI container tag."
}

output "server_image_tag" {
  value       = var.server_image_tag
  description = "Applied Vault Server UBI container tag."
}

output "github_organization" {
  value       = var.github_organization
  description = "Configured GitHub organization for Vault authentication."
}

output "github_admin_users" {
  value       = var.github_admin_users
  description = "Configured GitHub usernames mapped to the Vault 'admin' policy."
}
