terraform {
  backend "azurerm" {
    resource_group_name  = "lzniberRG"
    storage_account_name = "tfstatebilaniac"
    container_name       = "tfstate"
    key                  = "leith.terraform.tfstate"
  }
}