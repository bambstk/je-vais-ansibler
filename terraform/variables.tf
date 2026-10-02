variable "subscription_id" {
  description = "ID de la souscription Azure ciblée."
  type        = string
}

variable "resource_group_name" {
  description = "Nom du Resource Group existant dans lequel créer la VM et ses ressources réseau."
  type        = string
  default     = "lzniberRG"
}

variable "project_name" {
  description = "Nom court du projet, utilisé comme préfixe de nommage."
  type        = string
  default     = "oui-baguette"
}

variable "environment" {
  description = "Nom de l'environnement (dev, staging, prod…)."
  type        = string
  default     = "mystere"
}

variable "location_vm" {
  description = "Région Azure de la VM et de toutes ses ressources réseau (VNet, subnet, NSG, PIP, NIC, disque)."
  type        = string
  default     = "westeurope"
}

variable "allowed_ssh_source_ip" {
  description = "IP publique autorisée à se connecter en SSH (sera suffixée en /32). Ex : 203.0.113.42"
  type        = string
  # Pas de défaut : à renseigner explicitement.
}

variable "admin_username" {
  description = "Nom de l'utilisateur administrateur de la VM."
  type        = string
  default     = "azureuser"
}

variable "vm_size" {
  description = "Taille de la VM. Standard_D2s_v3 par défaut."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "vm_os_disk_size_gb" {
  description = "Taille du disque OS en Go."
  type        = number
  default     = 128
}

variable "tags" {
  description = "Tags additionnels appliqués aux ressources."
  type        = map(string)
  default     = {}
}