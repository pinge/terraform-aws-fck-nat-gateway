data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_ami" "this" {
  most_recent = true
  owners      = var.ami_owners
  filter {
    name   = "architecture"
    values = data.aws_ec2_instance_type.this.supported_architectures
  }
  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
}

# AWS ASGs do not support configuring source/destination check and it defaults to true, so we need to modify the network interface on boot
# by assuming a IAM role with permissions to modify the instance's network configuration.
# see https://github.com/terraform-aws-modules/terraform-aws-eks/issues/1008#issuecomment-691182478
data "aws_iam_policy_document" "this" {
  count = var.ha_enabled ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "ec2:ReplaceRoute",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:DetachNetworkInterface",
      "ec2:DescribeNetworkInterfaceAttribute",
      "ec2:DescribeNetworkInterfaces",
      "ec2:AttachNetworkInterface",
      "autoscaling:DescribeLifecycleHookTypes",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:CompleteLifecycleAction",
    ]
    # TODO improve access control to resources by the instance
    #      https://docs.aws.amazon.com/IAM/latest/UserGuide/access_iam-tags.html
    # filter access by ec2:RouteTableID for ec2:ReplaceRoute, ec2:Vpc and ec2:ResourceTag/${TagKey}
    # see https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html
    # see https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html#amazonec2-policy-keys
    resources = ["*"]
  }
}

locals {
  user_data_template = "${path.module}/user_data.sh"
  asg_name           = "${var.name}-asg"
  asg_hook_name      = "${var.name}-asg-launch-hook"
}

resource "aws_security_group" "this" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_security_group_rule" "this_egress" {
  security_group_id = aws_security_group.this.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
}

resource "aws_security_group_rule" "this_ingress" {
  security_group_id = aws_security_group.this.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
}

resource "aws_iam_policy" "this" {
  count  = var.ha_enabled ? 1 : 0
  name   = "${var.name}-policy"
  policy = data.aws_iam_policy_document.this[count.index].json
  tags   = local.tags
}

resource "aws_iam_role" "this" {
  count = var.ha_enabled ? 1 : 0
  name  = "${var.name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = {
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = [
          "ec2.amazonaws.com",
        ]
      }
    }
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  count      = var.ha_enabled ? 1 : 0
  role       = aws_iam_role.this[count.index].name
  policy_arn = aws_iam_policy.this[count.index].arn
}

resource "aws_iam_instance_profile" "this" {
  count = var.ha_enabled ? 1 : 0
  name  = "${var.name}-profile"
  role  = aws_iam_role.this[count.index].name
  tags  = local.tags
}

# This network interface is used as the public static IP addres of the NAT Gateway.
# Every Amazon EC2 instance has a primary ENI on eth0. This primary ENI cannot be detached from the instance.
# The NAT Gateway needs to keep a static public IP address so we don't have to update the aws_route resource
# with the network_interface_id every time the instances are rotated in the ASG.
# see https://stackoverflow.com/a/38155727
resource "aws_network_interface" "this" {
  count           = var.ha_enabled ? 1 : 0
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.this.id]
  # Disable source destination checking for the ENI so it can work as a NAT Gateway
  source_dest_check = false
  tags              = merge(local.tags, { Name = "${var.name}-main" })
}

resource "aws_network_interface" "warm_pool" {
  count           = var.ha_warm_pool ? 1 : 0
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.this.id]
  # Disable source destination checking for the ENI so it can work as a NAT Gateway
  source_dest_check = false
  tags              = merge(local.tags, { Name = "${var.name}-warm" })
}

resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-${var.ha_enabled ? "asg" : "i"}-"
  image_id               = data.aws_ami.this.id
  key_name               = var.key_name
  instance_type          = var.instance_type
  update_default_version = true
  # disable_api_stop       = true
  # disable_api_termination = true
  # In HA mode, load an environment variable with the ENI id so the fck-nat service can disable
  # source destination checking and attach the ENI to the EC2 instance. Include only in HA mode.
  user_data = var.ha_enabled ? base64encode(templatefile(local.user_data_template,
    {
      eni_id : aws_network_interface.this[0].id,
      warm_pool_eni_id : var.ha_warm_pool ? aws_network_interface.warm_pool[0].id : "",
      route_table_id : var.ha_warm_pool ? var.ha_route_table_id : "",
      asg_name : local.asg_name,
      asg_hook_name : local.asg_hook_name
  })) : null
  tags = local.tags

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  dynamic "iam_instance_profile" {
    for_each = var.ha_enabled ? [""] : []
    content {
      name = "${var.name}-profile"
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  monitoring {
    enabled = true
  }
}

# ha mode
resource "aws_autoscaling_group" "this" {
  count            = var.ha_enabled ? 1 : 0
  name             = local.asg_name
  min_size         = 1
  max_size         = 1
  desired_capacity = 1
  # set the health check grace period to 0 when using a lifecycle hook for instance launch
  health_check_grace_period = var.ha_enabled ? 0 : 60
  default_cooldown          = 15
  health_check_type         = "EC2"
  vpc_zone_identifier       = [var.subnet_id]

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "warm_pool" {
    for_each = var.ha_warm_pool ? [""] : []
    content {
      pool_state                  = "Running"
      min_size                    = 1
      max_group_prepared_capacity = 1

      instance_reuse_policy {
        reuse_on_scale_in = false
      }
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = []
  }
}

# takes about 1 minute from launch to cloud-init executig the script in user data
resource "aws_autoscaling_lifecycle_hook" "this" {
  count                  = var.ha_enabled ? 1 : 0
  name                   = local.asg_hook_name
  autoscaling_group_name = aws_autoscaling_group.this[count.index].name
  default_result         = "CONTINUE"
  heartbeat_timeout      = 300
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
}

# instance mode
resource "aws_instance" "this" {
  count     = var.ha_enabled ? 0 : 1
  subnet_id = var.subnet_id
  # Disable source destination checking for the ENI so it can work as a NAT Gateway
  source_dest_check = false
  key_name          = var.key_name
  tags              = local.tags

  launch_template {
    id = aws_launch_template.this.id
  }
}
