#!/bin/bash -ex

echo "###################Update package and add Repo Ussuri###################"
yum -y update
yum -y install epel-release
dnf -y install centos-release-openstack-ussuri
sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-OpenStack-ussuri.repo
dnf --enablerepo=centos-openstack-ussuri -y upgrade

echo "###################Install and Config Nova on Compute###################"

dnf -y install qemu-kvm libvirt virt-install
systemctl enable --now libvirtd

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-nova-compute

mv /etc/nova/nova.conf /etc/nova/nova.conf.org
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
my_ip = 192.168.1.6
state_path = /var/lib/nova
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
transport_url = rabbit://openstack:password@192.168.1.7

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
server_proxyclient_address = 192.168.1.6
novncproxy_base_url = http://192.168.1.7:6080/vnc_auto.html 

[glance]
api_servers = http://192.168.1.7:9292

[oslo_concurrency]
lock_path = $state_path/tmp

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.7:5000
auth_url = http://192.168.1.7:5000
memcached_servers = 192.168.1.7:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[cinder]
os_region_name = RegionOne

[placement]
auth_url = http://192.168.1.7:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[neutron]
auth_url = http://192.168.1.7:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = servicepassword
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

chmod 640 /etc/nova/nova.conf
chgrp nova /etc/nova/nova.conf

systemctl enable --now openstack-nova-compute

echo "###################Install and Config Neutron on Compute###################"

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

mv /etc/neutron/neutron.conf /etc/neutron/neutron.conf.org
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
allow_overlapping_ips = True
transport_url = rabbit://openstack:password@192.168.1.7

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.7:5000
auth_url = http://192.168.1.7:5000
memcached_servers = 192.168.1.7:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

[oslo_concurrency]
lock_path = $state_path/lock
EOF

chmod 640 /etc/neutron/neutron.conf
chgrp neutron /etc/neutron/neutron.conf

cat << EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = flat,vlan,gre,vxlan
tenant_network_types =
mechanism_drivers = openvswitch
extension_drivers = port_security

[ml2_type_flat]
flat_networks = provider
EOF

cat << EOF >> /etc/neutron/plugins/ml2/openvswitch_agent.ini
[securitygroup]
firewall_driver = openvswitch
enable_security_group = true
enable_ipset = true

[ovs]
bridge_mappings = provider:br-ex
EOF

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ens37

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
systemctl enable --now openvswitch
ovs-vsctl add-br br-int
systemctl restart openstack-nova-compute
systemctl enable --now neutron-openvswitch-agent
systemctl restart neutron-openvswitch-agent

echo "################### DONE ###################"
