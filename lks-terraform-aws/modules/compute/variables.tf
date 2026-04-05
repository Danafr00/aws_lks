variable "name_prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "bastion_instance_type" {
  type = string
}

variable "key_pair_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "ec2_sg_id" {
  type = string
}

variable "bastion_sg_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "alb_target_group_arn" {
  type = string
}

variable "min_capacity" {
  type = number
}

variable "max_capacity" {
  type = number
}

variable "desired_capacity" {
  type = number
}

variable "db_secret_arn" {
  type = string
}

variable "redis_endpoint" {
  type = string
}

variable "s3_bucket_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "project_name" {
  type = string
}
