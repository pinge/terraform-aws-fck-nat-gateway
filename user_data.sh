#!/usr/bin/env bash

echo "eni_id=${eni_id}" >> /etc/fck-nat.conf
echo "warm_pool_eni_id=${warm_pool_eni_id}" >> /etc/fck-nat.conf
echo "route_table_id=${route_table_id}" >> /etc/fck-nat.conf
echo "asg_name=${asg_name}" >> /etc/fck-nat.conf
echo "asg_hook_name=${asg_hook_name}" >> /etc/fck-nat.conf

# use single quotes around EOF to prevent parameter/arithmetic expansion and command substitution
cat >~/lifecycle.sh <<'EOF'
#!/usr/bin/env bash

poll_lock="/root/.poll.lock"
continue_file="/root/.lifecycle.continue"
pending_wait_lock="/root/.lifecycle.lock"
warmed_pending_wait_lock="/root/.lifecycle.warmed.lock"

if [[ -f "$continue_file" || -f "$poll_lock" ]]; then
    exit 0
fi

touch "$poll_lock"

. /etc/fck-nat.conf
. /usr/local/lib/aws-utils.sh

token="$(get_imds_token)"
region="$(get_region $token)"
instance_id=$(get_instance_id $token)
lifecycle_state=$(get_asg_lifecycle_state $token $instance_id)

# check for Pending:Wait lifecycle to start reattaching the network interface to this instance
if [[ "$lifecycle_state" == "Pending:Wait" && ! -f "$pending_wait_lock" ]]; then
    touch "$pending_wait_lock"
    if [[ -n "$warm_pool_eni_id" && -n "$route_table_id" ]]; then
        aws ec2 replace-route \
            --region $region \
            --route-table-id $route_table_id \
            --destination-cidr-block "0.0.0.0/0" \
            --network-interface-id $eni_id
    else
        # make sure to detch the network in case it's being used by another instance
        detach_network_interface $token $region $eni_id
    fi
    /usr/bin/systemctl enable fck-nat
    /sbin/service fck-nat restart
    # wait for fck-nat to start
    sleep 1
    while [ "$(systemctl is-active fck-nat)" == "activating" ]; do
        sleep 1
    done
    /usr/bin/crontab -r
    complete_lifecycle_action $token $region $asg_name $asg_hook_name $instance_id CONTINUE
    touch "$continue_file"
fi

# check for Warmed:Pending:Wait lifecycle so the instance can transition to Warmed:Running
if [[ "$lifecycle_state" == "Warmed:Pending:Wait" && ! -f "$warmed_pending_wait_lock" ]]; then
    touch "$warmed_pending_wait_lock"
    if [[ -n "$warm_pool_eni_id" && -n "$route_table_id" ]]; then
        healthy_instance_id=$(get_asg_healthy_instance_id $region $asg_name)
        if [[ -n "$healthy_instance_id" ]]; then
            if instance_has_network_interface_attached $region $healthy_instance_id $eni_id; then
                detach_network_interface $token $region $warm_pool_eni_id
                sed -i "s/^eni_id=.*/eni_id=$warm_pool_eni_id/" /etc/fck-nat.conf
                # continues to enabling fck-nat, does not return
            else
                detach_network_interface $token $region $eni_id
                # continues to enabling fck-nat, does not return
            fi
        else
            rm "$warmed_pending_wait_lock"
            rm "$poll_lock"
            exit 0
        fi
    fi
    /usr/bin/systemctl enable fck-nat
    /sbin/service fck-nat restart
    # wait for fck-nat to start
    sleep 1
    while [ "$(systemctl is-active fck-nat)" == "activating" ]; do
        sleep 1
    done
    complete_lifecycle_action $token $region $asg_name $asg_hook_name $instance_id CONTINUE
    rm "$poll_lock"
fi

EOF

chmod +x ~/lifecycle.sh

# crontab to check instance lifecycle state every 30 seconds (and keep existing crontab entries)
crontab<<EOF
$(crontab -l)
* * * * * ~/lifecycle.sh; sleep 30 && ~/lifecycle.sh
EOF

# check instance lifecycle state in the background so cloud-init can exit
~/lifecycle.sh &
