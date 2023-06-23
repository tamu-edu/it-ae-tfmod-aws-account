terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
      configuration_aliases = [ aws.root_acct, aws.linked_acct ]
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 1.6"
    }
    kion = {
      source = "Kionsoftware/Kion"
      version = "0.3.0"
    }
  }
}

##################
# Remote State
##################

data "terraform_remote_state" "config" {
  backend = "s3"
  config = {
    bucket = "aip-aws-foundation"
    key = "requirements/linked_acct/terraform.tfstate"
  }
}

data "terraform_remote_state" "org_units" {
  backend = "s3"
  config = {
    bucket = "aip-aws-foundation"
    key = "organizational_units/terraform.tfstate"
  }
}

##################
# AWS SSO requirements
##################

data "aws_ssoadmin_instances" "aip_sso" {
  provider = aws.root_acct #references the master payer acct
}

data "aws_ssoadmin_permission_set" "admin_access" {
  provider     = aws.root_acct
  instance_arn = tolist(data.aws_ssoadmin_instances.aip_sso.arns)[0] #creates list of arn::
  name         = "AdministratorAccess" #lists permission sets 
}

##################
# Data prerequisites
##################

data "azuread_users" "admins_group_members" {
  user_principal_names =tolist(concat(var.owner_data, ["aip-automation@tamu.edu"]))
}


data "azuread_users" "owners" {
  user_principal_names = tolist(concat(var.owner_data, ["aip-automation@tamu.edu"])) 
}

######################
# Resources
######################

# Create account resource
#
resource "aws_organizations_account" "account" {
  provider = aws.root_acct #creates linked account THROUGH aws organizations - the resource lives in master payer
  name      = "${var.account_name}"
  email     = var.email
  # There is no AWS Organizations API for reading role_name
  role_name = "OrganizationAccountAccessRole"
  parent_id = data.terraform_remote_state.org_units.outputs.aws_organizational_unit_internal.id
  tags      = {
    "Data Classification" = "${var.json_data.data_classification}"
    "FAMIS Account" = "${var.json_data.famis_account}"
    "Description" = "${var.json_data.resource_desc}"
  }
  lifecycle {
    ignore_changes = [tags,role_name]
    # prevent_destroy = true
  }
}

# Creates the Azure AD Group of Admins
#
resource "azuread_group" "admins_group" {
  display_name = "${var.account_name}-admins"
  owners  = concat(data.azuread_users.owners.object_ids, [var.aip_sp_cicd_aws_onboarding_object_id])

  # provisioner "local-exec" {
  #   command = <<EOT
  #     sleep 30 # allow time for object to come alive
  #     az rest --method POST \
  #             --uri https://graph.microsoft.com/v1.0/servicePrincipals/${ var.aws_sso_app.object_id }/appRoleAssignedTo \
  #             --body '{"appRoleId":   "${ var.aws_sso_app.approle_id} ", "principalId": "${ self.object_id }", "resourceId":  "${ var.aws_sso_app.object_id }"}' \
  #             --headers 'Content-Type=application/json' \
  #             --query '{ "id": id }'
  #   EOT
  # }

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

# Trigger a provisioning sync from Azure AD to the AWS Identity store
#
resource "null_resource" "sync_aws_sso" {
  # Wait until groups are populated before syncing
  depends_on = [  
    azuread_group_member.admins_group_members
    
  ]
  # Executes powershell that authenticates to the GraphAPI and triggers an immediate sync.
  # Script returns when the sync is complete
  provisioner "local-exec" {
    command = "pwsh sync.ps1"
    working_dir = "../../inc"
  }

  triggers = {
    "admin_group_object_id" = azuread_group.admins_group.id
    "admin_group_display_name" = azuread_group.admins_group.display_name
    
    "membership_ids"  = join(",", concat(data.azuread_users.admins_group_members.object_ids, [var.aip_sp_cicd_aws_onboarding_object_id]))
  }
}

resource "time_sleep" "sso_delay" {
  depends_on = [null_resource.sync_aws_sso]
  create_duration = "45s"

  triggers = {
    "sync_id" = null_resource.sync_aws_sso.id
  }
}

# Source the newly created or synced Admin group
#
data "aws_identitystore_group" "admins_group" {
  provider = aws.root_acct
  depends_on = [time_sleep.sso_delay] # Wait until sync is complete before sourcing resource

  identity_store_id = tolist(data.aws_ssoadmin_instances.aip_sso.identity_store_ids)[0]

  filter {
    attribute_path  = "DisplayName"
    attribute_value = azuread_group.admins_group.display_name
  }
}

# Assign Admin permission set to AIP Account Admin group
#
resource "aws_ssoadmin_account_assignment" "aip_admins" {
  provider = aws.root_acct
  instance_arn       = data.aws_ssoadmin_permission_set.admin_access.instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.admin_access.arn

  principal_id   = var.aws_sso_group_id.admins
  principal_type = "GROUP"

  target_id   = aws_organizations_account.account.id
  target_type = "AWS_ACCOUNT"
}

# Assign Admin permission set to Admin group
#
resource "aws_ssoadmin_account_assignment" "admins" {
  depends_on = [azuread_group.admins_group, data.aws_identitystore_group.admins_group]
  provider = aws.root_acct
  instance_arn       = data.aws_ssoadmin_permission_set.admin_access.instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.admin_access.arn

  principal_id   = data.aws_identitystore_group.admins_group.group_id
  principal_type = "GROUP"

  target_id   = aws_organizations_account.account.id
  target_type = "AWS_ACCOUNT"
}

# Assign Security permission set to Security groups
#
resource "aws_ssoadmin_account_assignment" "aws_sso_group_id_cyberdefense" {
  provider = aws.root_acct
  instance_arn       = data.aws_ssoadmin_permission_set.admin_access.instance_arn
  permission_set_arn = var.aws_permset_arn.cyberdefense

  principal_id   = var.aws_sso_group_id.cyberdefense
  principal_type = "GROUP"

  target_id   = aws_organizations_account.account.id
  target_type = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "aws_sso_group_id_secoperations" {
  provider = aws.root_acct
  instance_arn       = data.aws_ssoadmin_permission_set.admin_access.instance_arn
  permission_set_arn = var.aws_permset_arn.secoperations

  principal_id   = var.aws_sso_group_id.secoperations
  principal_type = "GROUP"

  target_id   = aws_organizations_account.account.id
  target_type = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "aws_sso_group_id_secassment" {
  provider = aws.root_acct
  instance_arn       = data.aws_ssoadmin_permission_set.admin_access.instance_arn
  permission_set_arn = var.aws_permset_arn.secassment

  principal_id   = var.aws_sso_group_id.secassment
  principal_type = "GROUP"

  target_id   = aws_organizations_account.account.id
  target_type = "AWS_ACCOUNT"
}

######################
# Kion Project (WIP)
######################

# workflow order:
# 1. create user_group in Kion
# 2. create saml_group_association of Azure AD group (depends on: user_group)
#     3. create project (depends on: user_group)
#       4. import account (can only be done manually or via API call, no Terraform provider resource available)
#         5. link account to project (depends on: project)(API call only, no Terraform provider resource available)

provider "kion" {
  url = "https://kion.cloud.tamu.edu"
  apikey = var.apikey
}

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
  name = "${var.account_name}-admins"
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

# resource "kion_project_cloud_access_role" {} <-- necessary?

#create project
resource "kion_project" "new_project" {
 name = "${var.account_name}"
 ou_id = data.kion_ou.master.list[0].id
 permission_scheme_id = 3 # default project permission scheme
 default_aws_region = "us-east-1"
 description = "${var.json_data.resource_desc}"
 owner_user_group_ids {
    id = kion_user_group.new_user_group.id 
 }
 owner_user_group_ids {
    id = data.kion_user_group.admins.list[0].id 
 }
 #work on this next
 project_funding {
  amount = 10000 # this amount is temporary; several older accounts list expenditure as '0'
  start_datecode = "2023-01"
  funding_source_id = var.funding_source_id
  end_datecode = "2023-08"
 }
}

#should make sure that all accounts associated with master payer are linked to Kion
resource "null_resource" "link_account_to_kion" {
  provisioner "local-exec" {
    command = <<EOT
      curl -X 'POST' \
        'https://kion.cloud.tamu.edu/api/v3/payer/1/link-all-accounts' \
        -H 'Authorization: Bearer ${var.apikey} \
        -H 'accept: application/json' \
        -d ''
      EOT

      #trigger? 
  }
}

#link account to project
resource "null_resource" "link_account_to_project" {
  depends_on = [kion_project.new_project, null_resource.link_account_to_kion]
  provisioner "local-exec" {
    command = <<EOT
      curl -X 'POST' \
        'https://kion.cloud.tamu.edu/api/v3/account?account-type=aws' \
        -H 'Authorization: Bearer ${var.apikey} \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        -d '{ 
        "account_email": "${var.email}",
        "account_name": "${var.account_name}",
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
}