#!/usr/bin/env bash
IFS=

install_puppet() {
    if [ ! -e "puppetlabs-release-pc1-xenial.deb" ]; then
        curl -O https://apt.puppetlabs.com/puppet5-release-xenial.deb
    fi
    sudo dpkg -i puppet5-release-xenial.deb
    sudo apt-get update && sudo apt-get install puppet-agent librarian-puppet -y && sudo apt-get dist-upgrade -y && sudo apt-get autoremove -y
    sudo ln -sf /opt/puppetlabs/puppet/bin/puppet /usr/local/bin/puppet
}

install_puppet_manifest_dependencies() {
    local INSTALL_CMD
    local CMD_OUT
    local CMD_EXIT_CODE
    INSTALL_CMD="cd /home/ubuntu/configs/puppet && librarian-puppet install"
    CMD_OUT=$(eval ${INSTALL_CMD})
    CMD_EXIT_CODE=$?
    if [ ${CMD_EXIT_CODE} -gt 0 ]; then
        echo >&2 "Executing Librarian-puppet installation step failed. Exit code: $?"
        exit 2
    fi
}

apply_puppet() {
    local APPLY_CMD
    local CMD_EXIT_CODE
    local LIVE_PUPPET_OUT
    echo "Applying puppet manifest..."

#
# --detailed-exitcodes
#    Provide extra information about the run via exit codes; only works if '--test' or '--onetime' is also specified. If enabled, 'puppet agent' will use the following exit codes:
#    0: The run succeeded with no changes or failures; the system was already in the desired state.
#    1: The run failed, or wasn't attempted due to another run already in progress.
#    2: The run succeeded, and some resources were changed.
#    4: The run succeeded, and some resources failed.
#    6: The run succeeded, and included both changes and failures.

    APPLY_CMD="puppet apply --detailed-exitcodes --logdest /home/ubuntu/configs/puppet.out --verbose /home/ubuntu/configs/puppet/environments/production/manifests/main.pp --modulepath=/home/ubuntu/configs/puppet/modules/ --hiera_config=/home/ubuntu/configs/puppet/hiera.yaml 2>&1"
    echo "Calling: ${APPLY_CMD}"
    LIVE_PUPPET_OUT=$(eval ${APPLY_CMD})
    CMD_EXIT_CODE=$?

    echo "Any non-logged puppet output: ${LIVE_PUPPET_OUT}"

    if [ ! -e "/home/ubuntu/configs/puppet.out" ]; then
        echo >&2 "Missing puppet.out!"
        exit 2
    fi

    if [ ${CMD_EXIT_CODE} -eq 1 ] || [ ${CMD_EXIT_CODE} -eq 4 ] || [ ${CMD_EXIT_CODE} -eq 6 ]; then
        echo >&2 "Applying puppet manifest failed. Exit code: ${CMD_EXIT_CODE}"
        echo "Puppet manifest application output:"
        cat "/home/ubuntu/configs/puppet.out"
        echo "${LIVE_PUPPET_OUT}"
        exit 2
    fi

    echo "Puppet output:"
    cat "/home/ubuntu/configs/puppet.out"
    echo "${LIVE_PUPPET_OUT}"

}

install_puppet
install_puppet_manifest_dependencies
apply_puppet

exit 0
