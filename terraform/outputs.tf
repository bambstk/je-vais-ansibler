output "vm_public_ip" {
  description = "Adresse IP publique de la VM runner."
  value       = azurerm_public_ip.runner.ip_address
}

output "ssh_private_key_pem" {
  description = "Clé privée SSH générée par Terraform. À récupérer via `terraform output -raw ssh_private_key_pem`."
  value       = tls_private_key.runner.private_key_pem
  sensitive   = true
}

output "vm_name" {
  description = "Nom de la VM."
  value       = azurerm_linux_virtual_machine.runner.name
}

output "nsg_name" {
  description = "Nom du NSG (utile au pipeline pour ouvrir/fermer la règle SSH temporaire)."
  value       = azurerm_network_security_group.runner.name
}

output "resource_group_name" {
  description = "Nom du Resource Group utilisé."
  value       = data.azurerm_resource_group.rg.name
}