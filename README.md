# AWS Cheap NAT Gateway module

Provision a NAT Gateway on AWS as a standalone instance or with high availability.

## Usage

Bake your Amazon Linux 2023 NAT AMI in the region(s) you need. The module will pick it up.

```bash
git clone -b cheap-nat-gateway https://github.com/pinge/fck-nat.git
cd fck-nat
make package-rpm-container
packer build \
	-only=fck-nat.amazon-ebs.fck-nat \
	-var 'region=us-east-1' \
	-var "version=$(cat Makefile | grep "^VERSION" | awk '{ print $3 }')" \
	-var-file="packer/fck-nat-arm64.pkrvars.hcl" \
	-var-file="packer/fck-nat-al2023.pkrvars.hcl" \
	packer/fck-nat.pkr.hcl
```

Simple NAT

```hcl
module "nat_gateway" {
  source          = "pinge/cheap-nat-gateway/aws"
  name            = "cheap-nat-gateway"
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.public_subnets[0]
  private_subnets = module.vpc.private_subnet_cidr_blocks
  ha_enabled      = false
}

resource "aws_route" "nat_gateway_route" {
  route_table_id         = module.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat_gateway.network_interface_id
}
```

High Availability NAT

```hcl
module "nat_gateway" {
  source          = "pinge/cheap-nat-gateway/aws"
  name            = "cheap-nat-gateway"
  vpc_id          = module.vpc.vpc_id
  subnet_id       = module.vpc.public_subnets[0]
  private_subnets = module.vpc.private_subnet_cidr_blocks
  ha_enabled      = true
}

resource "aws_route" "nat_gateway_route" {
  route_table_id         = module.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat_gateway.network_interface_id
}
```

High Availability NAT with warm pool

```hcl
module "nat_gateway" {
  source            = "pinge/cheap-nat-gateway/aws"
  name              = "cheap-nat-gateway"
  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.public_subnets[0]
  private_subnets   = module.vpc.private_subnet_cidr_blocks
  ha_enabled        = true
  ha_warm_pool      = true
  ha_route_table_id = module.vpc.main_route_table_id
}

resource "aws_route" "nat_gateway_route" {
  route_table_id         = module.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat_gateway_route.network_interface_id
  
  # required when enabling ha with warm pool
  lifecycle {
    ignore_changes = [
      network_interface_id
    ]
  }
}
```

Examples using a VPC provisioned with [terraform-aws-vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) and [aws_route](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route)

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_autoscaling_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_launch_template.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_network_interface.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/network_interface) | resource |
| [aws_network_interface.warm_pool](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/network_interface) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.this_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.this_ingress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_ami.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_ec2_instance_type.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_instance_type) | data source |
| [aws_iam_policy_document.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ami_name_filter"></a> [ami\_name\_filter](#input\_ami\_name\_filter) | n/a | `string` | `"cheap-nat-al2023-hvm-*"` | no |
| <a name="input_ami_owners"></a> [ami\_owners](#input\_ami\_owners) | n/a | `list(string)` | `["self"]` | no |
| <a name="input_ha_enabled"></a> [ha\_enabled](#input\_ha\_enabled) | n/a | `bool` | `true` | no |
| <a name="input_ha_route_table_id"></a> [ha\_route\_table\_id](#input\_ha\_route\_table\_id) | n/a | `string` | `null` | no |
| <a name="input_ha_warm_pool"></a> [ha\_warm\_pool](#input\_ha\_warm\_pool) | n/a | `bool` | `false` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | n/a | `string` | `"t4g.nano"` | no |
| <a name="input_key_name"></a> [key\_name](#input\_key\_name) | n/a | `string` | `null` | no |
| <a name="input_name"></a> [name](#input\_name) | n/a | `string` | `"cheap-nat-gateway"` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | n/a | `list(string)` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | n/a | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | n/a | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | n/a | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_network_interface_id"></a> [network\_interface\_id](#output\_network\_interface\_id) | n/a |
<!-- END_TF_DOCS -->

## Authors

This module is maintained by [Nuno Pinge](https://github.com/pinge).
