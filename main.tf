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
      source  = "github.com/kionsoftware/kion"
      version = "~> 0.3"
    }
  }
}

locals {
  owner_data = tolist(var.owners) 
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
  user_principal_names = tolist(local.owner_data)
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
  name      = "${var.account_name}"
  email     = var.account_email
  role_name = "OrganizationAccountAccessRole"
  parent_id = var.ou_id != "" ? var.ou_id : (
    var.data_classification == "Critical" ? data.terraform_remote_state.org_units.outputs.aws_organizational_unit_critical.id : (
      var.data_classification == "Confidential" ? data.terraform_remote_state.org_units.outputs.aws_organizational_unit_confidential.id : (
        var.data_classification == "University-Internal" ? data.terraform_remote_state.org_units.outputs.aws_organizational_unit_internal.id : (
          var.data_classification == "Public" ? data.terraform_remote_state.org_units.outputs.aws_organizational_unit_public.id : data.terraform_remote_state.org_units.outputs.aws_organizational_unit_tamu_exclude_from_all.id
        )
      )
    )
  )
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
  display_name = "aip-sg-aws-acct-${var.account_name}-admins"
  #display_name = "aip-sg-aws-acct-${var.business_unit}-${var.resource_name}-admins"
  owners  = concat(data.azuread_users.owners.object_ids, [var.aip_sp_cicd_aws_onboarding_object_id])
  security_enabled = true

  lifecycle {
    ignore_changes = [members, description, owners]
  }
}

# Populate the Admin group with members
#
resource "azuread_group_member" "admins_group_members" {
  for_each = toset(data.azuread_users.admins_group_members.object_ids)

  group_object_id  = azuread_group.admins_group.id
  member_object_id = each.value
}

