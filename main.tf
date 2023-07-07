terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 1.6"
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
  # There is no AWS Organizations API for reading role_name
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

######################
# Kion Project (WIP)
######################

# workflow order:
# 1. create user_group in Kion
# 2. create saml_group_association of Azure AD group (depends on: user_group)
#     3. create project (depends on: user_group, funding_source from outside module)
#       4. import account (can only be done manually or via API call, no Terraform provider resource available)
#         5. link account to project (depends on: project)(API call only, no Terraform provider resource available)
#           6. create project cloud access role (depends on: project, linked account API call)

data "kion_ou" "master"{
 filter {
   name = "name"
   values = ["TAMU"]
   regex = false
 }
}

data "kion_user_group" "admins" {
  filter {
    name = "name"
    values = ["admins"]
    regex = false
  }
}

#create user group
resource "kion_user_group" "new_user_group" {
  name = "${local.account_name}-admins"
  idms_id = 2 #Azure AD
  owner_groups {
    id = data.kion_user_group.admins.list[0].id 
  } 
}

#link user group to Azure AD group
resource "kion_saml_group_association" "link_to_azuread" {
  assertion_name = "memberOf"
  assertion_regex = azuread_group.admins_group.object_id
  idms_id = 2 #Azure AD
  update_on_login = true
  user_group_id = kion_user_group.new_user_group.id
}

#create project
# work on budget blocks using expenditure
resource "kion_project" "new_project" {
 name = "${local.account_name}"
 ou_id = data.kion_ou.master.list[0].id
 permission_scheme_id = 3 # default project permission scheme
 default_aws_region = "us-east-1"
 description = "${var.resource_desc}"
 owner_user_group_ids {
    id = kion_user_group.new_user_group.id 
 }
 owner_user_group_ids {
    id = data.kion_user_group.admins.list[0].id 
 }
 project_funding {
  amount = 10000 # this amount is temporary; several older accounts list expenditure as '0'
  start_datecode = "2023-01" 
  funding_source_id = var.funding_source_id
  # funding_source_id = data.kion_funding_source.project_funding_source.list[0].id
  end_datecode = "2023-09"
 }
 budget {
  amount = var.expenditure # this is going to be the amount specified by customers; likely to present errors for older ones.
  # data {
  #   amount = var.expenditure # this is going to be the amount specified by customers; likely to present errors for older ones.
  #   datecode = "" #required
  #   funding_source_id = var.funding_source_id
  #   priority = 1 #default
  # }
  funding_source_ids = [var.funding_source_id]
  start_datecode = "2023-01"
  end_datecode = "2023-09"
 }
}

# should make sure that all accounts associated with master payer are linked to Kion
## replace with linking single account
resource "null_resource" "link_account_to_kion" {
  provisioner "local-exec" {
    command = <<EOT
      curl -X 'POST' \
        'https://kion.cloud.tamu.edu/api/v3/payer/1/link-account' \
        -H 'Authorization: Bearer $KION_API_KEY \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        -d '{
        "account_email": "${local.email}",
        "account_name": "${local.account_name}",
        "account_number": "${aws_organizations_account.account.id}",
        "account_type_id": 1,
        "linked_account_number": ""
        }'
        EOT

  }
  #triggers = {}
}

#link account to project
resource "null_resource" "link_account_to_project" {
  depends_on = [kion_project.new_project, null_resource.link_account_to_kion]
  provisioner "local-exec" {
    command = <<EOT
      curl -X 'POST' \
        'https://kion.cloud.tamu.edu/api/v3/account?account-type=aws' \
        -H 'Authorization: Bearer $KION_API_KEY \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        -d '{ 
        "account_email": "${local.email}",
        "account_name": "${local.account_name}",
        "account_number": "${aws_organizations_account.account.id}",
        "account_type_id": 1,
        "include_linked_account_spend": true,
        "linked_aws_account_number": "",
        "linked_role": ${aws_organizations_account.account.role_name},
        "payer_id": 1,
        "project_id": ${kion_project.new_project.id},
        "skip_access_checking": false,
        "start_datecode": "2023-01",
        "use_org_account_info": false
        }'
      EOT
  }
  #triggers = {}
}
##Gives Admin Access for users connected to the account(s) linked to project
#
resource "kion_project_cloud_access_role" "new_project_cloud_access_role" {
  depends_on = [null_resource.link_account_to_project]

  name = "${local.account_name}-admin-access-role"
  project_id = kion_project.new_project.id
  user_groups {
    id = kion_user_group.new_user_group.id
  }

  ##workaround for not knowing account ID in advance
  ##applies to all accounts present in project
  apply_to_all_accounts = true
  ##how to pull account ID without account resource?
  # accounts {}
  future_accounts = true

  ##enable this, or not?
  # long_term_access_keys = true
  short_term_access_keys = true
  web_access = true

  #required
  aws_iam_role_name = "AdminAccessRole"
  #optional?
  # aws_iam_path = "" #string
  # aws_iam_permissions_boundary = #num
  
  aws_iam_policies {
    id = 1 #I *think* this is AdministratorAccess in Kion?
  }

  
}