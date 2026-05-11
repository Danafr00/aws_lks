variable "name_prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "rds_open_ingress" {
  description = "Open RDS port 3306 to 0.0.0.0/0. For learning only."
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Create WAF WebACL (NOT free tier)"
  type        = bool
  default     = false
}

variable "enable_kms_cmk" {
  description = "Create a KMS CMK (NOT free tier). Uses AWS-managed key when false."
  type        = bool
  default     = false
}
