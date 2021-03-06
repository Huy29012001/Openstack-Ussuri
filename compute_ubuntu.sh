#!/bin/bash -ex

source ans.inf
timedatectl set-timezone Asia/Ho_Chi_Minh

echo "###################Install and Config Nova on Compute###################"

apt -y install qemu-kvm libvirt-daemon-system libvirt-daemon virtinst bridge-utils libosinfo-bin libguestfs-tools virt-top
apt -y install nova-compute nova-compute-kvm qemu-system-data

mv /etc/nova/nova.conf /etc/nova/nova.conf.org
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
my_ip = $IP_COMPUTE_MANAGE
state_path = /var/lib/nova
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
transport_url = rabbit://openstack:$PASS_USER_RABBITMQ@$IP_CONTROLLER_MANAGE

use_neutron = True
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver
vif_plugging_is_fatal = True
vif_plugging_timeout = 300

[api]
auth_strategy = keystone

[vnc]
enabled = True
server_listen = 0.0.0.0
server_proxyclient_address = $IP_COMPUTE_MANAGE
novncproxy_base_url = http://$IP_CONTROLLER_MANAGE:6080/vnc_auto.html

[glance]
api_servers = http://$IP_CONTROLLER_MANAGE:9292

[oslo_concurrency]
lock_path = $state_path/tmp

[keystone_authtoken]
www_authenticate_uri = http://$IP_CONTROLLER_MANAGE:5000
auth_url = http://$IP_CONTROLLER_MANAGE:5000
memcached_servers = $IP_CONTROLLER_MANAGE:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $PASS_USER_NOVA

[placement]
auth_url = http://$IP_CONTROLLER_MANAGE:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = $PASS_USER_PLACEMENT

[neutron]
auth_url = http://$IP_CONTROLLER_MANAGE:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $PASS_USER_NEUTRON
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret

[cinder]
os_region_name = RegionOne

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

sed -i -e 's\lock_path = /tmp\lock_path = $state_path/tmp\g' /etc/nova/nova.conf

chmod 640 /etc/nova/nova.conf
chgrp nova /etc/nova/nova.conf
systemctl restart libvirtd nova-compute

echo "###################Install and Config Neutron on Compute###################"

apt -y install neutron-common neutron-plugin-ml2 neutron-openvswitch-agent

mv /etc/neutron/neutron.conf /etc/neutron/neutron.conf.org
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
allow_overlapping_ips = True
transport_url = rabbit://openstack:$PASS_USER_RABBITMQ@$IP_CONTROLLER_MANAGE

[agent]
root_helper = sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf

[keystone_authtoken]
www_authenticate_uri = http://$IP_CONTROLLER_MANAGE:5000
auth_url = http://$IP_CONTROLLER_MANAGE:5000
memcached_servers = $IP_CONTROLLER_MANAGE:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $PASS_USER_NEUTRON

[oslo_concurrency]
lock_path = $state_path/lock
EOF

sed -i -e 's\lock_path = /lock\lock_path = $state_path/lock\g' /etc/neutron/neutron.conf

chmod 640 /etc/neutron/neutron.conf
chgrp neutron /etc/neutron/neutron.conf

sed -i '/\[DEFAULT\]/a type_drivers = flat\ntenant_network_types =\nmechanism_drivers = openvswitch\nextension_drivers = port_security'  /etc/neutron/plugins/ml2/ml2_conf.ini
sed -i '/\[ml2_type_flat\]/a flat_networks = provider'  /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i '/\[ovs\]/a bridge_mappings = provider:br-ex' /etc/neutron/plugins/ml2/openvswitch_agent.ini
sed -i '/\[securitygroup\]/a firewall_driver = openvswitch\nenable_security_group = true\nenable_ipset = true' /etc/neutron/plugins/ml2/openvswitch_agent.ini

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

cat << EOF > /etc/systemd/network/$INTERFACE_BRIDGE.network
[Match]
Name=$INTERFACE_BRIDGE

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF

systemctl restart systemd-networkd openvswitch-switch

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex $INTERFACE_BRIDGE

systemctl restart nova-compute neutron-openvswitch-agent
systemctl enable neutron-openvswitch-agent

echo "################### DONE ###################"