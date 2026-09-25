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
  description = <<-EOT
    Must be unrestricted in BOTH regions for this subscription. Older sizes
    (B1s, B2s, D2s_v3, DS1_v2) are NotAvailableForSubscription on this Free
    Trial. Eight 2-vCPU v7 sizes are open in both West US and Central US;
    published West US Linux prices per hour: D2als_v7 $0.094, D2as_v7 $0.107,
    D2alds_v7 $0.112, D2ads_v7 $0.134, D2ls_v7 $0.153, D2s_v7 $0.173,
    D2lds_v7 $0.174, D2ds_v7 $0.213. The cheapest is plenty for a lab VM (4 GB
    RAM, no temp disk); the plan originally used D2ds_v7 at more than twice
    the price before the comparison was made.
  EOT
  type        = string
  default     = "Standard_D2als_v7"
}

variable "vm_names" {
  description = "One entry per VM tier. The canary runs just 'web' (2 vCPU); the regional quota is 4 vCPUs, so adding 'db' fills it exactly."
  type        = set(string)
  default     = ["web"]
}

variable "ubuntu_image_version" {
  description = "Pinned Ubuntu 24.04 marketplace image version, for reproducibility. It does not determine ASR kernel support (even this April image ships kernel 6.17) — see pinned_kernel."
  type        = string
  default     = "24.04.202604160"
}

variable "pinned_kernel" {
  description = "Kernel the VM boots. Must be in ASR's supported list for the Mobility agent build the vault installs (9.67.7789.1 supports Ubuntu 24.04 kernels up to 6.14.0-1017-azure; list lives in Azure/Azure-SiteRecovery on GitHub under MobilityAgent/AzureToAzure/SupportedKernels). Confirm with `uname -r` before enabling replication."
  type        = string
  default     = "6.14.0-1017-azure"
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
