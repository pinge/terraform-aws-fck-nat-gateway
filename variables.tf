variable "name" {
  type    = string
  default = "fck-nat-gateway"
}

variable "ha" {
  type = object({
    enabled = bool
  })
  default = {
    enabled = true
  }
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "ami_owners" {
  type    = list(string)
  default = ["568608671756"]
}

variable "ami_name_filter" {
  type    = string
  default = "fck-nat-amzn2-*"
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
