variable "name" {
  type    = string
  default = "cheap-nat-gateway"
}

variable "ha_enabled" {
  type    = bool
  default = true
}

variable "ha_warm_pool" {
  type    = bool
  default = false
}

variable "ha_route_table_id" {
  type    = string
  default = null
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "ami_owners" {
  type    = list(string)
  default = ["self"]
}

variable "ami_name_filter" {
  type    = string
  default = "cheap-nat-al2023-hvm-*"
}

variable "key_name" {
  type    = string
  default = null
}

variable "vpc_id" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "subnet_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  tags = merge({ Name = var.name }, var.tags)
}
