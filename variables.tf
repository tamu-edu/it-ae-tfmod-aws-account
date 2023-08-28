# passed from account.tf

variable "aip_sp_cicd_aws_onboarding_object_id" {}


variable "resource_name" { type = string }
variable "resource_desc" { type = string }
variable "owners" { type = list(string) }
variable "business_unit" { type = string }
variable "famis_account" { type = string }
variable "expenditure" { type = string }
variable "data_classification" { type = string }
variable "data_classification_artifact_url" { type = string }
variable "request_id" { type = string }
variable "account_name" { type = string }
variable "account_email" { type = string }
variable "ou_id" { type = string }
