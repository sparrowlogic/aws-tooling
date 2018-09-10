#!/usr/bin/env bash
## Bake out the AMI
AWS_PROFILE=""
AWS_REGION=""
INSTANCE_ID=""
NODE_FQDN=""
NOW=$(date +"%Y-%m-%d-%H-%M-%S")
create_ami() {
echo "Bake out the AMI"
AMI_ID=$(aws ec2 create-image --profile=${AWS_PROFILE} --region=${AWS_REGION} --instance-id ${INSTANCE_ID} --name ${NODE_FQDN}-${NOW} | jq -r '.ImageId')
IMAGE_CREATION_CHECK_COUNT=0
MAX_IMAGE_CREATION_CHECK_COUNT=500
while true; do
    IMAGE_CREATION_CHECK_COUNT=$(expr ${IMAGE_CREATION_CHECK_COUNT} + 1)
    if [ ${IMAGE_CREATION_CHECK_COUNT} -ge ${MAX_IMAGE_CREATION_CHECK_COUNT} ]; then
        echo >&2 "Been waiting for far too long to see the AMI created. Terminating the instance."
        INSTANCE_TERMINATION_OUT=$(aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" -out=json);
        echo >&2 ${INSTANCE_TERMINATION_OUT}
        exit 2
    fi
    IMAGE_CREATION_CHECK_CMD="aws ec2 describe-images --profile=${AWS_PROFILE} --region=${AWS_REGION} --filters Name=image-id,Values=${AMI_ID} --output json | jq '.Images[0].State'";
    IMAGE_STATUS=$(eval ${IMAGE_CREATION_CHECK_CMD})
    echo "Current image status: " ${IMAGE_STATUS}
    if [ "$(echo ${IMAGE_STATUS} | grep -i "available" | wc -l)" == "1" ]; then
        echo >&2 "AMI Successfully created! Moving onto the next step"
        echo ${AMI_ID}
        break;
    fi
    if [ "$(echo ${IMAGE_STATUS} | grep -i "failed" | wc -l)" == "1" ]; then
        echo >&2 "Image creation FAILED"
        //exit 2;
    fi
    echo >&2 "Sleeping for 30 seconds."
    sleep 30
done;
}
show_help() {
cat <<EOF
cat <<EOF
## CAUSES AN INSTANCE REBOOT ##
Creates an AMI using the current naming conventions
## CAUSES AN INSTANCE REBOOT ##
-h Display this menu
* -f {Desired node name. This is what we want to use as the left-half for name organization}
* -p AWS Profile name
* -r AWS Region (e.g., us-west-1)
* -m, Machine's instance ID (
* Indicated a required option.
EOF
EOF
}
check_minimum_arguments() {
    local VALID=1
    if [ -z ${INSTANCE_ID} ]; then
        echo >&2 "Missing instance ID to target changes on. Specify with the -m argument"
        local VALID=0
    fi
    if [ -z ${AWS_PROFILE} ]; then
        echo >&2 "Missing AWS Profile name. Specify with the -p argument"
        local VALID=0
    fi
    if [ -z ${AWS_REGION} ]; then
        echo >&2 "Missing AWS Region. Specify with the -r argument"
        local VALID=0;
    fi
    if [ -z ${NODE_FQDN} ]; then
        echo >&2 "Missing Node FQN Name. Specify with the -f argument."
        local VALID=0
    fi
    if [ ${VALID} -eq 0 ]; then
    exit 2;
    fi
}
while getopts 'hf:p:r:m:' OPTION; do
    case ${OPTION} in
        h)
            show_help
            exit 0
        ;;
        f)
            NODE_FQDN=$OPTARG
        ;;
        m)
            INSTANCE_ID=$OPTARG
        ;;
        p)
            AWS_PROFILE=$OPTARG
        ;;
        r)
            AWS_REGION=$OPTARG
        ;;
    esac
done
check_minimum_arguments
create_ami
echo ${AMI_ID}
exit 0