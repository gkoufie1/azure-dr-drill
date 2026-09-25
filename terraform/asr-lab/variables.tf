variable "subscription_id" {
  description = "Azure subscription ID — set in terraform.tfvars (gitignored), never committed"
  type        = string
}

variable "prefix" {
  description = "Short name prefix for resources"
  type        = string
  default     = "drdrill"
}

variable "source_location" {
  description = "Primary region. West US, not West US 2: Azure SQL provisioning is restricted in West US 2 on this subscription, and both labs share one region pair."
  type        = string
  default     = "westus"
}

variable "target_location" {
  description = "DR region. Central US — not Microsoft's paired region for West US (that's East US), chosen because it's the other region where both VM sizes and Azure SQL are available to this subscription."
  type        = string
  default     = "centralus"
}

variable "source_rg_name" {
  type    = string
  default = "rg-dr-drill-westus"
}

variable "target_rg_name" {
  type    = string
  default = "rg-dr-drill-centralus"
}

variable "vm_size" {
  description = "Must be unrestricted in BOTH regions for this subscription. Older sizes (B1s, B2s, D2s_v3, DS1_v2) are NotAvailableForSubscription on this Free Trial; D2ds_v7 is open in both."
  type        = string
  default     = "Standard_D2ds_v7"
}

variable "vm_names" {
  description = "One entry per VM tier. The canary runs just 'web' (2 vCPU); the regional quota is 4 vCPUs, so adding 'db' fills it exactly."
  type        = set(string)
  default     = ["web"]
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Public half only. The private key never leaves the local machine."
  type        = string
  default     = "~/.ssh/azure_VM1_rsa.pub"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "azure-dr-drill"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
