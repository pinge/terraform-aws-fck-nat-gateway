#!/usr/bin/env bash

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "asg_name=${asg_name}" >> /etc/fck-nat.conf
echo "asg_hook_name=${asg_hook_name}" >> /etc/fck-nat.conf

# use single quotes around EOF to prevent parameter/arithmetic expansion and command substitution
cat >~/lifecycle.sh <<'EOF'
#!/usr/bin/env bash

. /etc/fck-nat.conf

function get_token {
    echo $(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
}

function get_target_state {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/autoscaling/target-lifecycle-state)
}

function get_instance_id {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/instance-id)
}

function get_region {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/placement/region)
}

function get_ami_launch_index {
    echo $(curl -s -H "X-aws-ec2-metadata-token: $1" http://169.254.169.254/latest/meta-data/ami-launch-index)
}

function get_network_attachment_id {
    echo $(aws ec2 describe-network-interface-attribute --region $1 --network-interface-id $2 --attribute attachment \
        | grep -E -i -o 'AttachmentId": "(eni-attach-[a-z0-9]+)"' \
        | cut -f 2 -d ' ' \
        | tr -d '"')
}

function get_asg_lifecycle_state {
    echo $(aws autoscaling describe-auto-scaling-instances \
        --region $1 \
        --instance-ids $2 \
    | grep -E -i -o 'LifecycleState": "([A-Za-z:]+)"' \
    | cut -f 2 -d ' ' \
    | tr -d '"')
}

function complete_lifecycle_action {
    aws autoscaling complete-lifecycle-action \
        --region $1 \
        --auto-scaling-group-name $2 \
        --lifecycle-hook-name $3 \
        --instance-id $4 \
        --lifecycle-action-result $5
}

function detach_network_interface {
    attachment_id=$(get_network_attachment_id $1 $2)
    if [ -n "$attachment_id" ]; then
        aws ec2 detach-network-interface \
            --region $1 \
            --attachment-id $attachment_id \
            --force
        # wait until network interface is completely detached
        while [ -n "$attachment_id" ]; do
            attachment_id=$(get_network_attachment_id $1 $2)
            sleep 0.5
        done
    fi
}

token=$(get_token)
region=$(get_region $token)
instance_id=$(get_instance_id $token)
lifecycle_state=$(get_asg_lifecycle_state $region $instance_id)

# check for Pending:Wait lifecycle to start reattaching the network interface to this instance
if [[ "$lifecycle_state" == "Pending:Wait" && ! -f ~/lifecycle.lock ]]; then
    touch ~/lifecycle.lock
    detach_network_interface $region $eni_id
    /sbin/service fck-nat restart
    crontab -r
    complete_lifecycle_action $region $asg_name $asg_hook_name $instance_id CONTINUE
fi

# check for Warmed:Pending:Wait lifecycle so the instance can transition to Warmed:Running
if [[ "$lifecycle_state" == "Warmed:Pending:Wait" && ! -f ~/lifecycle.warmed.lock ]]; then
    touch ~/lifecycle.warmed.lock
    complete_lifecycle_action $region $asg_name $asg_hook_name $instance_id CONTINUE
fi

EOF

chmod +x ~/lifecycle.sh

# add crontab to check lifecycle state every 5 seconds
crontab<<EOF
$(crontab -l)
* * * * * for i in {0..11}; do ~/lifecycle.sh & sleep 5; done; touch ~/lifecycle.sh
EOF
