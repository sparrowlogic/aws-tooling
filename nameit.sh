#!/usr/bin/env bash
echo "$1" > /etc/hostname
fqdn=`cat /etc/hostname`
shortname=`cat /etc/hostname | cut -d "." -f1`
hostsfile="/etc/hosts"
cat <<EOM > /etc/hosts
127.0.0.1       $fqdn localhost $shortname
# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOM
/bin/hostname "$1"
echo "done."