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

# ACM cert ARN in us-east-1 for CloudFront custom domain (leave empty to use CF default cert)
variable "cloudfront_certificate_arn" {
  type    = string
  default = ""
}
