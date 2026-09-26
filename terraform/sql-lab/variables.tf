variable "subscription_id" {
  description = "Azure subscription ID: set in terraform.tfvars (gitignored), never committed"
  type        = string
}

variable "client_ip" {
  description = "Public IP of the machine running the writer script, allowed through both servers' firewalls. Set in terraform.tfvars (gitignored), never committed."
  type        = string
}

variable "primary_location" {
  description = "Primary region. West US: Azure SQL provisioning is restricted in East US, East US 2, West US 2 and others on this subscription."
  type        = string
  default     = "westus"
}

variable "secondary_location" {
  description = "DR region. Central US is not West US's Microsoft-paired region (that is East US). It is one of the few regions where Azure SQL is available to this subscription. Microsoft advises paired regions for failover groups, so this is a documented constraint."
  type        = string
  default     = "centralus"
}

variable "primary_rg_name" {
  type    = string
  default = "rg-dr-drill-westus"
}

variable "secondary_rg_name" {
  type    = string
  default = "rg-dr-drill-centralus"
}

variable "database_name" {
  type    = string
  default = "drilldb"
}

variable "database_sku" {
  description = "Standard S0 (10 DTUs), about $0.4839/day per database at published prices. The failover group creates the geo-secondary with the same tier."
  type        = string
  default     = "S0"
}

variable "admin_username" {
  type    = string
  default = "sqldrilladmin"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "azure-dr-drill"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}
