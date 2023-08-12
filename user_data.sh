#!/usr/bin/env bash

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "asg_name=${asg_name}" >> /etc/fck-nat.conf
echo "asg_hook_name=${asg_hook_name}" >> /etc/fck-nat.conf

# add single quotes around EOF to prevent parameter/arithmetic expansion and command substitution
cat >~/heal.sh <<'EOF'
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

function get_asg_lifecycle_state {
    echo $(aws autoscaling describe-auto-scaling-instances \
        --region $1 \
        --instance-ids $2 \
    | grep -E -i -o 'LifecycleState": "([A-Za-z:]+)"' \
    | cut -f 2 -d ' ' \
    | tr -d '"')
}

token=$(get_token)
region=$(get_region $token)
instance_id=$(get_instance_id $token)
lifecycle_state=$(get_asg_lifecycle_state $region $instance_id)

# check for Pending:Wait lifecycle to start reattaching the network interface to this instance
if [[ "$lifecycle_state" == "Pending:Wait" && ! -f ~/heal.lock ]]; then

    touch ~/heal.lock

    # get ENI attachment id
    attachment_id=$(aws ec2 describe-network-interface-attribute \
        --region $region \
        --attribute attachment \
        --network-interface-id $eni_id \
        | grep -E -i -o 'AttachmentId": "(eni-attach-[a-z0-9]+)"' \
        | cut -f 2 -d ' ' \
        | tr -d '"')

    # force detaching the ENI
    if [ -n "$attachment_id" ]; then
        aws ec2 detach-network-interface \
            --region $region \
            --attachment-id $attachment_id \
            --force
    fi

    # complete asg lifecycle action so the instance can transition from 'Pending:Wait' to 'InService'
    aws autoscaling complete-lifecycle-action \
        --lifecycle-hook-name $asg_hook_name \
        --auto-scaling-group-name $asg_name \
        --lifecycle-action-result CONTINUE \
        --instance-id $instance_id \
        --region $region

    # wait until network interface is completely detached
    while [ -n "$attachment_id" ]; do
        attachment_id=$(aws ec2 describe-network-interface-attribute \
            --region $region \
            --attribute attachment \
            --network-interface-id $eni_id \
            | grep -E -i -o 'AttachmentId": "(eni-attach-[a-z0-9]+)"' \
            | cut -f 2 -d ' ' \
            | tr -d '"')
        sleep 0.5
    done

    # restart fck-nat so the ENI is attached to the instance and routes are configured properly
    /sbin/service fck-nat restart

    crontab -r

fi

# check for Warmed:Pending:Wait lifecycle so the instance can transition to Warmed:Running
if [[ "$lifecycle_state" == "Warmed:Pending:Wait" && ! -f ~/warmed.lock ]]; then

    touch ~/warmed.lock

    # complete asg lifecycle action so the instance can be added to the warmed pool
    aws autoscaling complete-lifecycle-action \
        --lifecycle-hook-name $asg_hook_name \
        --auto-scaling-group-name $asg_name \
        --lifecycle-action-result CONTINUE \
        --instance-id $instance_id \
        --region $region

fi

EOF

chmod +x ~/heal.sh

# add crontab to check lifecycle state every 5 seconds
crontab<<EOF
$(crontab -l)
* * * * * for i in {0..11}; do ~/heal.sh & sleep 5; done; touch ~/heal.sh
EOF
