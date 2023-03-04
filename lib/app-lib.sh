#!/bin/bash

# global SSH_OPTS
# global EC2_INSTANCE_TYPE
# global EC2_VOLUME_SIZE
# global EC2_VOLUME_TYPE
# global EC2_KEY_PAIR
# global EC2_SECURITY_GROUP
# global SKIP_PHASES
# global AWS_REGION

is_phase_skipped() {
    # global SKIP_PHASES

    local phase="$1"

    echo "$SKIP_PHASES" | grep -q "$phase"
}

press_any_key_to_continue() {
    read -n 1 -s -r -p $'Press any key to continue\n'
}

signal() {
    for _ in {1..10}; do
        echo -en "\007"
    done
}

wait_until_instance_will_be_up() {
    local instance_id="$1"
    local max_attempts="${2:-5}"
    local interval="${3:-15}"

    local attempt=0

    while : ; do
        attempt=$(expr $attempt + 1)

        einfo "Waiting until instance will be up ($attempt/$max_attempts)..."

        [ "$(get_instance_state $instance_id)" = "running" ] && break || true
        [ $attempt = $max_attempts ] && return 1 || true

        sleep $interval
    done
}

wait_until_spot_request_fulfilled() {
    local request_id="$1"
    local max_attempts="${2:-5}"
    local interval="${3:-15}"

    local attempt=0

    while : ; do
        attempt=$(expr $attempt + 1)

        einfo "Waiting until spot request will be fulfilled ($attempt/$max_attempts)..."

        local spot_request_status=$(get_spot_request_status "$request_id")

        if [ "$spot_request_status" = "capacity-not-available" ]; then
            edie "There are no available spot instances with desired instance type. Try later or use on-demand instance with option \"--spot-instance no\"."
        fi

        [ "$spot_request_status" = "fulfilled" ] && break || true
        [ $attempt = $max_attempts ] && return 1 || true

        sleep $interval
    done
}

wait_until_ssh_will_be_up() {
    # global SSH_OPTS

    local user="$1"
    local host="$2"
    local max_attempts="${3:-5}"
    local interval="${4:-15}"

    local attempt=0

    while : ; do
        attempt=$(expr $attempt + 1)

        einfo "Waiting until SSH will be up ($attempt/$max_attempts)..."

        ssh $SSH_OPTS "$user@$host" "exit" && break || true
        [ $attempt = $max_attempts ] && return 1 || true

        sleep $interval
    done
}

verify_image_state() {
    local image_id="$1"

    if [ "$(get_image_state $image_id)" = "failed" ]; then
        edie "AMI image creation has failed."
    fi
}

wait_until_image_will_be_available() {
    local image_id="$1"
    local max_attempts="${2:-30}"
    local interval="${3:-60}"

    local attempt=0

    while : ; do
        attempt=$(expr $attempt + 1)

        einfo "Waiting until AMI image will be available ($attempt/$max_attempts)..."

        [ "$(get_image_state $image_id)" = "available" ] && break || true
        [ $attempt = $max_attempts ] && return 1 || true

        sleep $interval
    done
}

get_last_amzn2_image() {
    local arch="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --filters "Name=owner-alias,Values=amazon" \
                  "Name=name,Values=amzn2-ami-hvm-2.0.*-$arch-gp2" \
        --query "reverse(sort_by(Images, &CreationDate))[0].ImageId" \
        --output text
}

get_image_root_volume_snapshot_id() {
    local image_id="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$image_id" \
        --query "Images[0].BlockDeviceMappings[0].Ebs.SnapshotId" \
        --output text
}

get_image_virtualization_type() {
    local image_id="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$image_id" \
        --query "Images[0].VirtualizationType" \
        --output text
}

get_image_architecture() {
    local image_id="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$image_id" \
        --query "Images[0].Architecture" \
        --output text
}

get_instance_state() {
    local instance_id="$1"

    eexec -p aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text
}

get_instance_public_ip() {
    local instance_id="$1"

    eexec -p aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Association.PublicIp' \
        --output text
}

get_spot_request_status() {
    local request_id="$1"

    eexec -p aws ec2 describe-spot-instance-requests \
        --region "$AWS_REGION" \
        --spot-instance-request-ids "$request_id" \
        --query 'SpotInstanceRequests[0].Status.Code' \
        --output text
}

get_spot_request_instance_id() {
    local request_id="$1"

    eexec -p aws ec2 describe-spot-instance-requests \
        --region "$AWS_REGION" \
        --spot-instance-request-ids "$request_id" \
        --query 'SpotInstanceRequests[0].InstanceId' \
        --output text
}

run_instance() {
    # global EC2_INSTANCE_TYPE
    # global EC2_VOLUME_SIZE
    # global EC2_VOLUME_TYPE
    # global EC2_KEY_PAIR
    # global EC2_SUBNET_ID (optional)
    # global EC2_SECURITY_GROUP

    [ -z "$EC2_INSTANCE_TYPE" ] && edie "Unable to launch EC2 instance without provided Instance Type."
    [ -z "$EC2_VOLUME_SIZE" ] && edie "Unable to launch EC2 instance without provided Volume Size."
    [ -z "$EC2_VOLUME_TYPE" ] && edie "Unable to launch EC2 instance without provided Volume Type."
    [ -z "$EC2_KEY_PAIR" ] && edie "Unable to launch EC2 instance without provided Key Pair."
    [ -n "$EC2_SUBNET_ID" ] && [ -n "$EC2_SECURITY_GROUP" ] && ( echo "$EC2_SECURITY_GROUP" | grep -vq '^sg-') && edie "If Subnet is specified then Group must be an ID (\"sg-XXX\")"
    [ -z "$EC2_SUBNET_ID" ] && [ -z "$EC2_SECURITY_GROUP" ] && edie "Unable to launch EC2 instance without providing either Subnet ID or Security Group name or ID."

    local image_id="$1"
    local shapshot_id="$2"
    # market is "spot" or omitted
    local market="$3"

    local device_mapping_file="$(mktemp --suffix=.json)"

    cat > "$device_mapping_file" <<- END
[
    {
        "DeviceName": "/dev/xvda",
        "Ebs": {
            "DeleteOnTermination": true,
            "SnapshotId": "$shapshot_id",
            "VolumeSize": $EC2_VOLUME_SIZE,
            "VolumeType": "$EC2_VOLUME_TYPE"
        }
    },{
        "DeviceName": "/dev/xvdb",
        "Ebs": {
            "DeleteOnTermination": $(eon "$KEEP_BOOTSTRAP_DISK" && echo false || echo true),
            "VolumeSize": $EC2_VOLUME_SIZE,
            "VolumeType": "$EC2_VOLUME_TYPE"
        }
    }
]
END
    local opt_args=()

    if [ -n "$EC2_SUBNET_ID" ]; then
        # VPC
        local ni_args="DeviceIndex=0,AssociatePublicIpAddress=true,SubnetId=$EC2_SUBNET_ID"
        if [ -n "$EC2_SECURITY_GROUP" ]; then
            ni_args+=",Groups=$EC2_SECURITY_GROUP"
        fi
        opt_args+=(--network-interfaces $ni_args)
    else
        # Possibly Classic
        opt_args+=(--associate-public-ip-address)
        if [ -n "$EC2_SECURITY_GROUP" ]; then
            # If group begins with "sg-" then its an ID rather than a name.
            if echo "$EC2_SECURITY_GROUP" | grep -q '^sg-'; then
                opt_args+=(--security-group-ids "$EC2_SECURITY_GROUP")
            else
                opt_args+=(--security-groups "$EC2_SECURITY_GROUP")
            fi
        fi
    fi

    # unlimited credit specification is only for t2 instances
    # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/t2-unlimited.html
    if echo "$EC2_INSTANCE_TYPE" | grep -q '^t2\.'; then
        opt_args+=(--credit-specification '{"CpuCredits":"unlimited"}')
    fi

    if [ "x$market" == "xspot" ]; then
        opt_args+=(--instance-market-options MarketType="spot")
        opt_args+=(--query "Instances[0].SpotInstanceRequestId")
    else
        opt_args+=(--query "Instances[0].InstanceId")
    fi

    eexec -p aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$image_id" \
        --instance-type "$EC2_INSTANCE_TYPE" \
        --key-name "$EC2_KEY_PAIR" \
        --block-device-mappings "file://$device_mapping_file" \
        ${opt_args[*]} \
        --output text

    local result=$?

    rm "$device_mapping_file"

    return $result
}

terminate_instance() {
    local instance_id="$1"

    eexec aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id"
}

remove_snapshot() {
    local snapshot_id="$1"

    eexec aws ec2 delete-snapshot \
        --region "$AWS_REGION" \
        --snapshot-id "$snapshot_id"
}

create_image() {
    local instance_id="$1"
    local name="$2"

    eexec -p aws ec2 create-image \
        --region "$AWS_REGION" \
        --instance-id "$instance_id" \
        --name "$name" \
        --description "$name" \
        --block-device-mappings '[{"DeviceName":"/dev/xvdb","NoDevice":""}]' \
        --query "ImageId" \
        --output text
}

remove_image() {
    local image_id="$1"

    eexec aws ec2 deregister-image \
        --region "$AWS_REGION" \
        --image-id "$image_id"
}

get_image_state() {
    local image_id="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$image_id" \
        --query "Images[0].State" \
        --output text
}

get_image_snapshots() {
    local image_id="$1"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$image_id" \
        --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' \
        --output text
}

get_account_id() {
    eexec -p aws sts get-caller-identity \
        --region "$AWS_REGION" \
        --query "Account" \
        --output text
}

get_outdated_images() {
    local account_id="$1"
    local name_prefix="$2"
    local new_image_id="$3"

    eexec -p aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners "$account_id" \
        --filters "Name=name,Values=$name_prefix *" \
        --query "Images[?ImageId!=\`$new_image_id\`].ImageId" \
        --output text
}

remove_outdated_images() {
    local account_id="$1"
    local name_prefix="$2"
    local new_image_id="$3"

    local old_images
    local old_image_id
    local old_snapshots
    local old_snapshot_id

    einfo "Searching for outdated AMI images with prefix \"$name_prefix\" in account..."
    old_images="$(get_outdated_images "$account_id" "$name_prefix" "$new_image_id")"

    if [ -n "$old_images" ]; then
        for old_image_id in $old_images; do
            old_snapshots="$(get_image_snapshots "$old_image_id")"

            einfo "Deregistering outdated AMI image $old_image_id..."
            remove_image "$old_image_id"

            eindent

            for old_snapshot_id in $old_snapshots; do
                einfo "Removing related snapshot $old_snapshot_id..."
                remove_snapshot "$old_snapshot_id"
            done

            eoutdent
        done
    else
        einfo "No outdated images were found."
    fi
}
