terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Compute, Network, Storage and RecoveryServices are already registered on
  # this subscription (checked with `az provider show` before building), so
  # the provider doesn't need to try registering anything itself.
  resource_provider_registrations = "none"
}
