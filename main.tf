terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
    kion = {
      source = "github.com/kionsoftware/kion"
      version = "0.3.3"
    }
  }
}

locals {
  account_name = "${var.business_unit}-${var.resource_name}" 
  owner_data = tolist(var.owners) 
  email = "aip-aws-root+${local.account_name}@tamu.edu"
}

##################
# Remote State
##################

data "terraform_remote_state" "org_units" {
  backend = "s3"
  config = {
    bucket = "aip-aws-foundation"
    key = "organizational_units/terraform.tfstate"
  }
}

##################
# Data prerequisites
##################

data "azuread_users" "admins_group_members" {
  user_principal_names =tolist(concat(local.owner_data, ["aip-automation@tamu.edu"]))
}


data "azuread_users" "owners" {
  user_principal_names = tolist(concat(local.owner_data, ["aip-automation@tamu.edu"])) 
}

######################
# Resources
######################

# Create account resource
#
resource "aws_organizations_account" "account" {
  provider = aws #creates linked account THROUGH aws organizations - the resource lives in master payer
  name      = "${local.account_name}"
  email     = local.email
  role_name = "OrganizationAccountAccessRole"
  parent_id = data.terraform_remote_state.org_units.outputs.aws_organizational_unit_internal.id
  tags      = {
    "Data Classification" = "${var.data_classification}"
    "FAMIS Account" = "${var.famis_account}"
    "Description" = "${var.resource_desc}"
  }
  lifecycle {
    ignore_changes = [tags,role_name]
    # prevent_destroy = true
  }
}

# Creates the Azure AD Group of Admins
#
resource "azuread_group" "admins_group" {
  display_name = "${local.account_name}-admins"
  owners  = concat(data.azuread_users.owners.object_ids, [var.aip_sp_cicd_aws_onboarding_object_id])
  security_enabled = true

  lifecycle {
    ignore_changes = [members, description, owners]
  }
}

# Populate the Admin group with members
#
resource "azuread_group_member" "admins_group_members" {
  for_each = toset(concat(data.azuread_users.admins_group_members.object_ids, [var.aip_sp_cicd_aws_onboarding_object_id]))

  group_object_id  = azuread_group.admins_group.id
  member_object_id = each.value
}

