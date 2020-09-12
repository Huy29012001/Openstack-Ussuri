#!/bin/bash

echo "###################Disable SELinux and Firewall###################"

sed -i -e "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config

systemctl disable --now firewalld

cat << EOF >> /etc/hosts
192.168.1.7 controller
192.168.1.6 compute
EOF

echo "###################Reboot System###################"
reboot