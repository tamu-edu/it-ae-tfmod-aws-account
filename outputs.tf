######################
# Outputs
######################

output "account" {
  value = aws_organizations_account.account
}

output "admins_group" {
  value = azuread_group.admins_group
}