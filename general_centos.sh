#!/bin/bash

echo "###################Disable SELinux and Firewall###################"

sed -i -e "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config

systemctl disable --now firewalld

cat << EOF >> /etc/hosts
$IP_CONTROLLER_MANAGE controller
$IP_COMPUTE_MANAGE compute
EOF

echo "###################Reboot System###################"
reboot