#!/usr/bin/env bash
## set to empty so newlines aren't smushed
IFS=
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

##PWD of this script. Used by rsync
SOURCE=$(dirname "$0")
if [ "${SOURCE}" = '.' ]; then
SOURCE=$(pwd)
fi

##################### REQUIRED ARGUMENTS ###################

# -f
NODE_FQDN=""

# -a
BASE_AMI=""

# -p
AWS_PROFILE=""

# -i
SSH_PRIVATE_KEY_PATH=""

# -g
AWS_SECURITY_GROUP=""

# -r
AWS_REGION=""

# -s
AWS_SUBNET_ID=""

# -k
AWS_PROVISIONING_KEY_NAME=""

# -t
TERMINATE_WHEN_DONE=1

# -e
EC2_INSTANCE_TYPE="t2.micro"

############## END OF REQUIRED ARGUMENTS ###################

##################### OPTIONAL ARGUMENTS ###################


# -o
AWS_IAM_PROFILE=""

############## END OF OPTIONAL ARGUMENTS ###################


show_help() {
cat <<"EOF"
## Create a new AMI for a given instance node-name definition in puppet. ##

Special notes: The IAM Profile performing this must be able to create and terminate instances, access security groups, and create AMIs

-h Display this menu
* -a - Base AMI to start with (See: https://cloud-images.ubuntu.com/locator/ec2/  Suggested: ami-059e7901352ebaef8)
  -e EC2 instance type. E.g., t2.micro (default)
* -f {Desired node name. This is what we want to use as the left-half for name organization}
* -g AWS Security Group
* -i PATH on the system executing this command to the SSH Key to authenticate against the instance with. Must correspond to the -g argument's key name on AWS.
* -k AWS Root SSH Key name (e.g., root_key_pair -- This MUST correspond to the -i SSH-key being used)
* -p AWS Profile name
* -r AWS Region (e.g., us-west-1)
* -s AWS Subnet to put the instance under (Must be internet routable)
* -o AWS IAM prOfile ;-) -- this is needed if the puppet manifest needs to install AWS CodeDeploy  because that requires S3 permissions.
* -t Keep the instance alive even if there's a failure along the way -- e.g., you want to spin up an instance and keep on fiddling with puppet after it breaks.


* Indicated a required option.

EOF
}

function my_trap_handler()
{
        MYSELF="$0"               # equals to my script name
        LASTLINE="$1"            # argument 1: last line of error occurence
        LASTERR="$2"             # argument 2: error code of last command
        echo >&2 "${MYSELF}: line ${LASTLINE}: exit status of last command: ${LASTERR}"

        # do additional processing: send email or SNMP trap, write result to database, etc.
}


check_minimum_arguments() {
    local VALID=1

    if [ -z ${BASE_AMI} ]; then
        echo >&2 -e "${RED}Missing base AMI.${NC} Set with the -a argument."
        VALID=0
    fi

    if [ -z ${NODE_FQDN} ]; then
        echo >&2 -e "${RED}Missing Node Fully Qualified Domain Name.${NC} Specify with the -f argument."
        VALID=0
    fi

    if [ -z ${AWS_SECURITY_GROUP} ]; then
        echo >&2 -e "${RED}Missing AWS Security Group ID.${NC} Specify with the -g argument."
        VALID=0
    fi


    if [ -z ${SSH_PRIVATE_KEY_PATH} ]; then
        echo >&2 -e "${RED}Missing SSH Key Path.${NC} Specify with the -i argument."
        VALID=0
    fi

    if [ ! -e ${SSH_PRIVATE_KEY_PATH} ]; then
        echo >&2 -e "${RED}Provided SSH Key path in argument -i does not exist.${NC}"
        VALID=0
    fi

    if [ -z ${AWS_PROVISIONING_KEY_NAME} ]; then
        echo >&2 -e "${RED}Provided SSH Provisioning Key name (On AWS) was not set.${NC} Set with the -k argument."
        VALID=0
    fi

    if [ -z ${AWS_PROFILE} ]; then
        echo >&2 -e "${RED}Missing AWS Profile name.${NC} Specify with the -p argument"
        VALID=0
    fi

    if [ -z ${AWS_REGION} ]; then
        echo >&2 -e "${RED}Missing AWS Region.${NC} Specify with the -r argument"
        VALID=0;
    fi

    if [ -z ${AWS_SUBNET_ID} ]; then
        echo >&2 -e "${RED}Missing AWS Subnet ID.${NC} Specify with the -s argument"
        VALID=0;
    fi

    if [ ${VALID} -eq 0 ]; then
        echo -e "\n\n${YELLOW}##########################################################${NC}"
        echo -e "${YELLOW}#     For usage instructions, provide the -h argument    #${NC}"
        echo -e "${YELLOW}##########################################################${NC}\n"
        exit 2;
    fi
}

check_expected_commands_exist() {
    AWS_CLI_CMD=$(which aws);

    if [ -z ${AWS_CLI_CMD} ]; then
        echo -e >&2 "${RED}AWS CLI command was not found${NC}";
        exit 2
    fi;

    JQ_CMD=$(which jq);

    if [ -z ${JQ_CMD} ]; then
        echo -e >&2 "${RED}jq command not installed. install jq.${NC}";
        exit 2
    fi;
    echo >&2 -e "${GREEN}All necessary CLI commands installed. moving to next step.${NC}"
}

sanity_check_provided_arguments() {
    local SECURITY_GROUP_EXISTS
    local BASE_AMI_EXISTS

    SECURITY_GROUP_EXISTS=$(aws ec2 describe-security-groups --no-paginate --region=${AWS_REGION} --profile=${AWS_PROFILE} --output=json --filters Name=group-id,Values=${AWS_SECURITY_GROUP} | jq -r '.SecurityGroups[0].GroupName' | wc -l)

    if [ ${SECURITY_GROUP_EXISTS} -eq 0 ]; then
        echo >&2 'supplied security group does not exist. Ensure that already exists before creating an instance with that security group.'
        exit 2;
    fi

    BASE_AMI_EXISTS=$(aws ec2 describe-images --profile=${AWS_PROFILE} --region=${AWS_REGION} --no-paginate --filter Name=image-id,Values=${BASE_AMI} --output=json | jq -r '.Images[0].Description' | wc -l)

    if [ ${BASE_AMI_EXISTS} -eq 0 ]; then
        echo >&2 "supplied AMI ID, ${BASE_AMI} does not exist in the requested region. Please check the AMI ID supplied against what is available in that region."
        exit 2;
    fi


    if [ ! -z "${AWS_IAM_PROFILE}" ]; then
        echo >&2 "Checking IAM Profile exists..."
        local COUNT_OF_ROLES
        local ROLE_CHECK_CMD
        ROLE_CHECK_CMD="aws iam list-instance-profiles | jq '.InstanceProfiles[].Roles[]' | jq -r '.RoleName' | grep '${AWS_IAM_PROFILE}' | wc -l"
        COUNT_OF_ROLES=$(eval ${ROLE_CHECK_CMD})
        if [ ${COUNT_OF_ROLES} - eq 0 ]; then
            echo >&2 -e "${RED}IAM INSTANCE PROFILE NOT FOUND!${NC}"
            exit 2
        fi

    fi

    echo >&2 -e "${GREEN}Arguments look sane. Moving to next step.${NC}"
}



create_instance() {
    echo >&2 "entering create_instance command"

    local CREATION_CMD
    local CREATION_OUTPUT
    local CREATION_SUCCESSFUL
    local IAM_PROFILE_SET;
    IAM_PROFILE_SET=""

    if [ ! -z ${AWS_IAM_PROFILE} ]; then
        IAM_PROFILE_SET="--iam-instance-profile '{\"Name\":\"${AWS_IAM_PROFILE}\"}' "
    fi

    CREATION_CMD="aws ec2 run-instances --profile ${AWS_PROFILE} --image-id ${BASE_AMI} ${IAM_PROFILE_SET}--region ${AWS_REGION} --subnet-id ${AWS_SUBNET_ID} --security-group-ids ${AWS_SECURITY_GROUP} --count 1 --instance-type ${EC2_INSTANCE_TYPE} --key-name ${AWS_PROVISIONING_KEY_NAME} --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=TEMPORARY_${NODE_FQDN}}]' --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=50,DeleteOnTermination=true}' --associate-public-ip-address --output json 2>&1"

    echo >&2 -e "${GREEN}Calling EC2 Instance creation command:${NC} ${CREATION_CMD}"

    CREATION_OUTPUT=$(eval ${CREATION_CMD});
    CREATION_SUCCESSFUL=$?

    if [ ${CREATION_SUCCESSFUL} -gt 0 ]; then
        echo >&2 -e "${RED}Unable to create the instance. Exit code: ${CREATION_SUCCESSFUL} output: ${CREATION_OUTPUT}${NC}"
        exit 2
    fi

    INSTANCE_ID=$(echo ${CREATION_OUTPUT} | jq -r '.Instances[0].InstanceId')

    if [ -z "${INSTANCE_ID}" ]; then
        echo >&2 'unable to create the requested instance.'
        exit 2;
    fi
    echo >&2 -e "${GREEN}Instance created. Instance ID: ${INSTANCE_ID}. Moving on to the next step.${NC}"
}

instance_up_watch() {
    echo >&2 "Instance ID: ${INSTANCE_ID}"
    local INSTANCE_IS_UP_CHECK_COUNT=0
    local MAX_WAIT_COUNT=500
    local INSTANCE_STATUS_CHECK_CMD

    while true; do
        INSTANCE_IS_UP_CHECK_COUNT=$(expr ${INSTANCE_IS_UP_CHECK_COUNT} + 1)

        if [ ${INSTANCE_IS_UP_CHECK_COUNT} -ge ${MAX_WAIT_COUNT} ]; then
            echo >&2 -e "${RED}Been waiting for far too long. Terminating the instance and exiting.${NC}"
            exit 2
        fi

        echo >&2 "sleeping for 10 seconds."
        sleep 10;


        INSTANCE_STATUS_CHECK_CMD="aws ec2 describe-instance-status --profile=${AWS_PROFILE} --region=${AWS_REGION} --instance-ids ${INSTANCE_ID} --output=json | jq -r '.InstanceStatuses[0].InstanceStatus.Status'";
        INSTANCE_STATUS=$(eval ${INSTANCE_STATUS_CHECK_CMD})
        echo >&2 "Current instance status: " ${INSTANCE_STATUS}
        if [ "$(echo ${INSTANCE_STATUS} | grep -i "ok" | wc -l)" == "1" ]; then
            echo >&2 "INSTANCE RUNNING. Continuing into next steps."
            break;
        fi
        if [ "$(echo ${INSTANCE_STATUS} | grep -i "failed" | wc -l)" == "1" ]; then
            echo >&2 "Instance never came up. Terminating"
            exit 2;
        fi
    done;
}

get_public_ip_from_instance_id() {
    PUBLIC_IP_ADDRESS=$(aws ec2 describe-instances --filters Name=instance-id,Values=${INSTANCE_ID} --profile ${AWS_PROFILE} --region ${AWS_REGION} --output json | jq -r '.Reservations[0].Instances[0].PublicIpAddress')
    echo >&2 "PUBLIC IP: ${PUBLIC_IP_ADDRESS}"
}


name_the_remote_system() {
    local NAME_IT_CMD
    NAME_IT_CMD="ssh -q -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_PRIVATE_KEY_PATH} ubuntu@${PUBLIC_IP_ADDRESS} \"sudo /home/ubuntu/configs/nameit.sh ${NODE_FQDN}\" 2>&1"
    echo >&2 "Now executing: ${NAME_IT_CMD}"
    echo >&2 "Naming the instance to ${NODE_FQDN}"
    NAME_IT_OUTPUT=$(eval ${NAME_IT_CMD});
    echo >&2 ${NAME_IT_OUTPUT};
}

rsync_configs_folder() {
    IFS=
    ## rsync this folder up to the instance.
    echo >&2 "Creating configs path on instance"
    local MKDIR_COMMAND
    local MKDIR_SUCCESS
    local MK_CONF_DIR_OUTPUT
    local RSYNC_OUTPUT
    local RSYNC_OUTPUT_SUCCESS

    MKDIR_COMMAND="ssh -q -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_PRIVATE_KEY_PATH} ubuntu@${PUBLIC_IP_ADDRESS} \"sudo rm -rf ~/configs; mkdir -p ~/configs\" 2>&1"
    echo >&2 "calling SSH mkdir command: ${MKDIR_COMMAND}"

    MK_CONF_DIR_OUTPUT=$(eval ${MKDIR_COMMAND});
    MKDIR_SUCCESS=$?
    if [ ${MKDIR_SUCCESS} -gt 0 ]; then
        echo >&2 "Unable to create directory. output: ${MK_CONF_DIR_OUTPUT}"
        exit 2
    fi
    echo echo >&2 ${MK_CONF_DIR_OUTPUT}


    RSYNC_COMMAND="rsync -e \"ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_PRIVATE_KEY_PATH}\" --exclude ${SOURCE}/../puppet/.librarian --exclude ${SOURCE}/../puppet/modules/ --exclude ${SOURCE}/../puppet/.tmp -a --stats --delete ${SOURCE}/../ ubuntu@${PUBLIC_IP_ADDRESS}:/home/ubuntu/configs 2>&1"
    echo >&2 "Calling rsync command: ${RSYNC_COMMAND}"
    RSYNC_OUTPUT=$(eval ${RSYNC_COMMAND});
    RSYNC_OUTPUT_SUCCESS=$?
    if [ ${RSYNC_OUTPUT_SUCCESS} -gt 0 ];
    then
        echo >&2 -e "${RED}RSYNC failed! exit code: $?${NC}"
        exit 2
    fi
    echo >&2 ${RSYNC_OUTPUT}
    echo >&2 "Finished rsync step"
}

update_remote_packages() {
    ## Update all dependencies on the OS
    UPDATE_CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"sudo apt-get update; sudo apt-get dist-upgrade -y; sudo apt-get autoremove -y;\" 2>&1"

    UPDATE_PACKAGES_OUTPUT=$(eval ${UPDATE_CMD})
}

install_puppet() {
    local CMD
    local CMD_OUTPUT
    local CMD_EXIT_CODE
    CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"cd /home/ubuntu && curl -O https://apt.puppetlabs.com/puppet5-release-xenial.deb && sudo dpkg -i puppet5-release-xenial.deb && sudo apt-get update && sudo apt-get install puppet-agent librarian-puppet -y && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y && sudo ln -sf /opt/puppetlabs/puppet/bin/puppet /usr/local/bin/puppet && sudo dpkg -l | grep puppet;\" 2>&1"
    echo >&2 "Installing puppet: ${CMD}"
    CMD_OUTPUT=$(eval ${CMD})
    CMD_EXIT_CODE=$?

    if [ ${CMD_EXIT_CODE} -gt 0 ]; then
        echo >&2 -e "${RED}Error installing puppet.${NC}"
        echo >&2 ${CMD_OUTPUT}
        exit 2
    fi
    echo >&2 "finished installing puppet"
    echo >&2 "${CMD_OUTPUT}"
}

librarian_puppet_install() {
    local CMD
    local CMD_OUTPUT
    local CMD_EXIT_CODE
    CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"cd /home/ubuntu/configs/puppet && mkdir -p /home/ubuntu/configs/puppet/modules && librarian-puppet install --clean --verbose;\" 2>&1"

    echo >&2 "starting librarian-puppet install: ${CMD}"
    CMD_OUTPUT=$(eval ${CMD})
    CMD_EXIT_CODE=$?

    if [ ${CMD_EXIT_CODE} -gt 0 ]; then
        echo >&2 -e "${RED}Error installing librarian-puppet dependencies.${NC}"
        echo >&2 "${CMD_OUTPUT}"
        exit 2
    fi
    echo >&2 "${CMD_OUTPUT}"
    echo >&2 "Finished librarian-puppet install --clean."
}

apply_puppet_manifest() {
    local CMD
    local CMD_OUTPUT
    local CMD_EXIT_CODE
    CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"sudo puppet apply --logdest syslog --detailed-exitcodes /home/ubuntu/configs/puppet/environments/production/manifests/main.pp --modulepath=/home/ubuntu/configs/puppet/modules/ --hiera_config=/home/ubuntu/configs/puppet/hiera.yaml;\" 2>&1"

    echo >&2 "Applying puppet manifests: ${CMD}"
    CMD_OUTPUT=$(eval ${CMD})
    CMD_EXIT_CODE=$?

    ## Exit code 2 means changes were applied see --detailed-exitcodes in puppet apply documentation.
    if [ ${CMD_EXIT_CODE} -ne 2 ]; then
        echo >&2 -e "${RED}Error Applying puppet manifest. Exit code: ${CMD_EXIT_CODE}${NC}"
        echo >&2 ${CMD_OUTPUT}
        CAT_SYSLOG="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"sudo cat /var/log/syslog\""
        echo >&2 $(eval ${CAT_SYSLOG})
        exit 2
    fi


    echo >&2 "finished applying puppet manifest."
}

remove_puppet_agent() {
    local REMOVE_PUPPET_CMD
    local REMOVE_PUPPET_OUTPUT
    local REMOVE_PUPPET_SUCCESS
    echo >&2 "Removing puppet-agent from the machine"
    ## remove puppet-agent
    REMOVE_PUPPET_CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"sudo apt-get purge puppet-agent -y\" 2>&1"
    echo >&2 "Executing ${REMOVE_PUPPET_CMD}"
    REMOVE_PUPPET_OUTPUT=$(eval ${REMOVE_PUPPET_CMD})
    REMOVE_PUPPET_SUCCESS=$?
    if [ ${REMOVE_PUPPET_SUCCESS} -gt 0 ]; then
        echo >&2 -e "${RED}Removing puppet-agent failed. Exit code: $?${NC}"
        exit 2
    fi
    echo >&2 "removal of puppet: ${REMOVE_PUPPET_OUTPUT}"
}

remove_configs_folder() {
    local REMOVE_CONFIGS_PATH_CMD
    local REMOVE_CONFIGS_OUTPUT
    ## Remove configs folder
    REMOVE_CONFIGS_PATH_CMD="ssh -q -t ubuntu@${PUBLIC_IP_ADDRESS} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i \"${SSH_PRIVATE_KEY_PATH}\" \"sudo rm -rf /home/ubuntu/configs\" 2>&1"
    REMOVE_CONFIGS_OUTPUT=$(eval ${REMOVE_CONFIGS_PATH_CMD})
    if [ $? -gt 0 ]; then
        echo >&2 -e "${RED}Removing /home/ubuntu/configs path failed. Exit code: $?${NC}"
        exit 2
    fi
    echo >&2 "Configurations directory removed for cleanliness."
}

bake_ami() {
    echo >&2 "Puppet exited properly with all changes to the system being successful. Baking out an AMI."
    local CREATE_AMI_CMD
    local BAKE_AMI_OUTPUT

    ## Bake out the AMI
    CREATE_AMI_CMD="./ami_creation/create_ami_from_instance.sh -m ${INSTANCE_ID} -p ${AWS_PROFILE} -r ${AWS_REGION} -f ${NODE_FQDN} 2>&1"
    BAKE_AMI_OUTPUT=$(eval ${CREATE_AMI_CMD})
    echo >&2 ${BAKE_AMI_OUTPUT}
    echo >&2 "finished bake_ami function. Moving on to the next step."
}

terminate_instance() {
    local TERMINATION_CMD
    local INSTANCE_TERMINATION_OUT

    if [ -z ${INSTANCE_ID} ]; then
        return 1
    fi

    ## don't terminate the instance if -t is supplied
    if [ ${TERMINATE_WHEN_DONE} -eq 0 ]; then
        return 1
    fi


    TERMINATION_CMD="aws ec2 terminate-instances --region ${AWS_REGION} --profile ${AWS_PROFILE} --instance-ids \"${INSTANCE_ID}\" --output=json"
    echo >&2 "Terminating instance by calling: ${TERMINATION_CMD} after a 15 second sleep period."
    sleep 15
    INSTANCE_TERMINATION_OUT=$(eval ${TERMINATION_CMD});
    echo >&2 "Termination output: ${INSTANCE_TERMINATION_OUT}"
}


while getopts 'ha:e:f:g:i:k:o:p:r:s:t' OPTION; do
    case ${OPTION} in
        h)
            show_help
            exit 0
        ;;
        a)
            BASE_AMI=$OPTARG
        ;;
        e)
            EC2_INSTANCE_TYPE=$OPTARG
        ;;
        f)
            NODE_FQDN=$OPTARG
        ;;
        g)
            AWS_SECURITY_GROUP=$OPTARG
        ;;
        i)
            SSH_PRIVATE_KEY_PATH=$OPTARG
        ;;
        k)
            AWS_PROVISIONING_KEY_NAME=$OPTARG
        ;;
        m)
            INSTANCE_ID=$OPTARG
        ;;
        o)
            AWS_IAM_PROFILE=$OPTARG
        ;;
        p)
            AWS_PROFILE=$OPTARG
        ;;
        r)
            AWS_REGION=$OPTARG
        ;;
        s)
            AWS_SUBNET_ID=$OPTARG
        ;;
        t)
            echo >&2 -e "${RED}NOT TERMINATING INSTANCE REGARDLESS OF FAILURES OR SUCCESSES${NC}"
            TERMINATE_WHEN_DONE=0
        ;;
        v)
            EBS_VOLUME_ID=$OPTARG
        ;;
    esac
done

function finish {
    terminate_instance
}
trap finish EXIT
trap 'my_trap_handler ${LINENO} $?' ERR

check_minimum_arguments
check_expected_commands_exist
sanity_check_provided_arguments
create_instance
instance_up_watch
get_public_ip_from_instance_id

## on the instance
rsync_configs_folder
name_the_remote_system

## puppet commands
install_puppet
librarian_puppet_install
apply_puppet_manifest

## instance cleanup
remove_puppet_agent
remove_configs_folder


bake_ami
## Terminate instance is always called due to EXIT trap. ##
#terminate_instance
## end of terminate instance step

exit 0