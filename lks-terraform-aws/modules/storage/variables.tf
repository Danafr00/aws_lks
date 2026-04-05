variable "name_prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "domain_name" {
  type    = string
  default = ""
}
