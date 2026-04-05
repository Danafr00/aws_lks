variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "waf_acl_arn" {
  type = string
}

variable "enable_deletion_protection" {
  type = bool
}

variable "logs_bucket_id" {
  type = string
}

variable "domain_name" {
  type    = string
  default = ""
}
