#!/usr/bin/env bash

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "warm_pool_eni_id=${warm_pool_eni_id}" >> /etc/fck-nat.conf
echo "route_table_id=${route_table_id}" >> /etc/fck-nat.conf
echo "asg_name=${asg_name}" >> /etc/fck-nat.conf
echo "asg_hook_name=${asg_hook_name}" >> /etc/fck-nat.conf

# use single quotes around EOF to prevent parameter/arithmetic expansion and command substitution
cat >~/lifecycle.sh <<'EOF'
#!/usr/bin/env bash

. /etc/fck-nat.conf

function get_token {
    echo $(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
}

function get_instance_id {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/instance-id)
}

function get_region {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/placement/region)
}

function get_asg_lifecycle_state {
    echo $(aws autoscaling describe-auto-scaling-instances \
        --instance-ids $1 \
        --query "AutoScalingInstances[0].LifecycleState" \
        --output text)
}

function get_asg_healthy_instance_id {
    echo $(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names $1 \
        --query "AutoScalingGroups[].Instances[? (LifecycleState == 'InService') && (HealthStatus == 'Healthy')][].InstanceId | [0]" \
        --output text)
}

function complete_lifecycle_action {
    aws autoscaling complete-lifecycle-action \
        --auto-scaling-group-name $1 \
        --lifecycle-hook-name $2 \
        --instance-id $3 \
        --lifecycle-action-result $4
}

function get_network_attachment_id {
    echo $(aws ec2 describe-network-interface-attribute \
        --network-interface-id $1 \
        --attribute attachment \
        --query "Attachment.AttachmentId" \
        --output text)
}

function detach_network_interface {
    attachment_id=$(get_network_attachment_id $1)
    if [ "$attachment_id" != "None" ]; then
        aws ec2 detach-network-interface \
            --attachment-id $attachment_id \
            --force
        # wait until network interface is completely detached
        while [ "$attachment_id" != "None" ]; do
            attachment_id=$(get_network_attachment_id $1)
            sleep 0.5
        done
    fi
}

function instance_has_network_interface_attached {
    has=$(aws ec2 describe-network-interface-attribute \
        --network-interface-id $2 \
        --attribute attachment \
        --query "Attachment.InstanceId == '$1'")
    [ "$has" == "true" ] && return 0 || return 1
}

token=$(get_token)
region=$(get_region $token)
aws configure set region $region

instance_id=$(get_instance_id $token)
lifecycle_state=$(get_asg_lifecycle_state $instance_id)

# check for Pending:Wait lifecycle to start reattaching the network interface to this instance
if [[ "$lifecycle_state" == "Pending:Wait" && ! -f ~/lifecycle.lock ]]; then
    touch ~/lifecycle.lock
    if [[ -n "$warm_pool_eni_id" && -n "$route_table_id" ]]; then
        aws ec2 replace-route \
            --route-table-id $route_table_id \
            --destination-cidr-block "0.0.0.0/0" \
            --network-interface-id $eni_id
    else
        detach_network_interface $eni_id
    fi
    /sbin/service fck-nat restart
    crontab -r
    complete_lifecycle_action $asg_name $asg_hook_name $instance_id CONTINUE
fi

# check for Warmed:Pending:Wait lifecycle so the instance can transition to Warmed:Running
if [[ "$lifecycle_state" == "Warmed:Pending:Wait" && ! -f ~/lifecycle.warm.lock ]]; then
    touch ~/lifecycle.warm.lock
    if [[ -n "$warm_pool_eni_id" && -n "$route_table_id" ]]; then
        healthy_instance_id=$(get_asg_healthy_instance_id $asg_name)
        if [[ -n "$healthy_instance_id" ]]; then
            if instance_has_network_interface_attached $healthy_instance_id $eni_id; then
                detach_network_interface $warm_pool_eni_id
                sed -i "s/^eni_id=.*/eni_id=$warm_pool_eni_id/" /etc/fck-nat.conf
                /sbin/service fck-nat restart
            else
                detach_network_interface $eni_id
                /sbin/service fck-nat restart
            fi
        else
            rm ~/lifecycle.warm.lock
            exit 0
        fi
    fi
    complete_lifecycle_action $asg_name $asg_hook_name $instance_id CONTINUE
fi

EOF

chmod +x ~/lifecycle.sh

# add crontab to check lifecycle state every 5 seconds
crontab<<EOF
$(crontab -l)
* * * * * for i in {0..11}; do ~/lifecycle.sh & sleep 5; done; touch ~/lifecycle.sh
EOF
