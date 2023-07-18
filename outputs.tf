######################
# Outputs
######################

output "org_account" {
  value = aws_organizations_account.account.id
}

output "role_name" {
  value = aws_organizations_account.account.role_name
}

output "admins_group" {
  value = azuread_group.admins_group.object_id
}
