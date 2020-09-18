#!/bin/bash

echo "###################Disable SELinux and Firewall###################"

sed -i -e "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config

systemctl disable --now firewalld

cat << EOF >> /etc/hosts
192.168.1.40 controller
192.168.1.41 compute
EOF

echo "###################Reboot System###################"
reboot