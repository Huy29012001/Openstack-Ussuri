#!/bin/bash -ex
timedatectl set-timezone Asia/Ho_Chi_Minh

echo "###################Install and Config MariaDB###################"

apt -y install mariadb-server
systemctl restart mariadb

sed -i -e "s/127.0.0.1/0.0.0.0/g" /etc/mysql/mariadb.conf.d/50-server.cnf
sed -i -e "s/#max_connections        = 100/max_connections        = 500/g" /etc/mysql/mariadb.conf.d/50-server.cnf
sudo mysql -e "SET PASSWORD FOR root@localhost = PASSWORD('Nam@12345');FLUSH PRIVILEGES;" 

cat << EOF | mysql -uroot -pNam@12345
DROP DATABASE IF EXISTS keystone;
DROP DATABASE IF EXISTS glance;
DROP DATABASE IF EXISTS nova;
DROP DATABASE IF EXISTS nova_api;
DROP DATABASE IF EXISTS nova_cell0;
DROP DATABASE IF EXISTS placement;
DROP DATABASE IF EXISTS cinder;
DROP DATABASE IF EXISTS neutron_ml2;

create database keystone;
grant all privileges on keystone.* to keystone@'localhost' identified by 'password';
grant all privileges on keystone.* to keystone@'%' identified by 'password';

create database glance;
grant all privileges on glance.* to glance@'localhost' identified by 'password';
grant all privileges on glance.* to glance@'%' identified by 'password';

create database nova;
grant all privileges on nova.* to nova@'localhost' identified by 'password';
grant all privileges on nova.* to nova@'%' identified by 'password';

create database nova_api;
grant all privileges on nova_api.* to nova@'localhost' identified by 'password';
grant all privileges on nova_api.* to nova@'%' identified by 'password';

create database nova_cell0;
grant all privileges on nova_cell0.* to nova@'localhost' identified by 'password';
grant all privileges on nova_cell0.* to nova@'%' identified by 'password';

create database placement;
grant all privileges on placement.* to placement@'localhost' identified by 'password';
grant all privileges on placement.* to placement@'%' identified by 'password';

create database cinder;
grant all privileges on cinder.* to cinder@'localhost' identified by 'password';
grant all privileges on cinder.* to cinder@'%' identified by 'password';

create database neutron_ml2; 
grant all privileges on neutron_ml2.* to neutron@'localhost' identified by 'password'; 
grant all privileges on neutron_ml2.* to neutron@'%' identified by 'password'; 
flush privileges;

EOF

systemctl restart mysql

echo "###################Install and Config RabbitMQ && Memcached###################"

apt -y install rabbitmq-server memcached python3-pymysql

rabbitmqctl add_user openstack password
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

sed -i -e "s/127.0.0.1/0.0.0.0/g" /etc/memcached.conf

echo "###################Install and Config Keystone###################"

apt -y install keystone python3-openstackclient apache2 libapache2-mod-wsgi-py3 python3-oauth2client

sed -i -e "s/#memcache_servers = localhost:11211/memcache_servers = 192.168.1.40:11211/g" /etc/keystone/keystone.conf
sed -i -e "s\connection = sqlite:////var/lib/keystone/keystone.db\connection = mysql+pymysql://keystone:password@192.168.1.40/keystone\g" /etc/keystone/keystone.conf
sed -i -e "s/#provider = fernet/provider = fernet/g" /etc/keystone/keystone.conf

su -s /bin/bash keystone -c "keystone-manage db_sync"

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password adminpassword --bootstrap-admin-url http://192.168.1.40:5000/v3/ --bootstrap-internal-url http://192.168.1.40:5000/v3/ --bootstrap-public-url http://192.168.1.40:5000/v3/ --bootstrap-region-id RegionOne

systemctl restart apache2


cat << EOF > ~/keystonerc
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=adminpassword
export OS_AUTH_URL=http://localhost:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export PS1='[\u@\h \W(keystone)]\$ '
export OS_VOLUME_API_VERSION=3
EOF

chmod 600 ~/keystonerc
source ~/keystonerc
echo "source ~/keystonerc " >> ~/.bash_profile

openstack project create --domain default --description "Service Project" service

echo "###################Install and Config Glance###################"

openstack user create --domain default --project service --password servicepassword glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create --region RegionOne image public http://192.168.1.40:9292
openstack endpoint create --region RegionOne image internal http://192.168.1.40:9292
openstack endpoint create --region RegionOne image admin http://192.168.1.40:9292

apt -y install glance

mv /etc/glance/glance-api.conf /etc/glance/glance-api.conf.org
cat << EOF > /etc/glance/glance-api.conf
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/

[database]
connection = mysql+pymysql://glance:password@192.168.1.40/glance

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.40:5000
auth_url = http://192.168.1.40:5000
memcached_servers = 192.168.1.40:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = servicepassword

[paste_deploy]
flavor = keystone
EOF

chmod 640 /etc/glance/glance-api.conf
chown root:glance /etc/glance/glance-api.conf

su -s /bin/bash glance -c "glance-manage db_sync"
systemctl restart glance-api

echo "###################Install and Config Nova on Controller###################"

openstack user create --domain default --project service --password servicepassword nova
openstack role add --project service --user nova admin

openstack user create --domain default --project service --password servicepassword placement
openstack role add --project service --user placement admin

openstack service create --name nova --description "OpenStack Compute service" compute
openstack service create --name placement --description "OpenStack Compute Placement service" placement

openstack endpoint create --region RegionOne compute public http://192.168.1.40:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://192.168.1.40:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute admin http://192.168.1.40:8774/v2.1/%\(tenant_id\)s

openstack endpoint create --region RegionOne placement public http://192.168.1.40:8778
openstack endpoint create --region RegionOne placement internal http://192.168.1.40:8778
openstack endpoint create --region RegionOne placement admin http://192.168.1.40:8778

apt -y install nova-api nova-conductor nova-scheduler nova-novncproxy placement-api python3-novaclient

mv /etc/nova/nova.conf /etc/nova/nova.conf.org
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
my_ip = 192.168.1.40
state_path = /var/lib/nova
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
transport_url = rabbit://openstack:password@192.168.1.40

use_neutron = True
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver

[api]
auth_strategy = keystone

[glance]
api_servers = http://192.168.1.40:9292

[oslo_concurrency]
lock_path = $state_path/tmp

[api_database]
connection = mysql+pymysql://nova:password@192.168.1.40/nova_api

[database]
connection = mysql+pymysql://nova:password@192.168.1.40/nova

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.40:5000
auth_url = http://192.168.1.40:5000
memcached_servers = 192.168.1.40:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[placement]
auth_url = http://192.168.1.40:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[cinder]
os_region_name = RegionOne

[neutron]
auth_url = http://192.168.1.60:5000
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
mv /etc/placement/placement.conf /etc/placement/placement.conf.org

cat << EOF > /etc/placement/placement.conf
[DEFAULT]
debug = false

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.40:5000
auth_url = http://192.168.1.40:5000
memcached_servers = 192.168.1.40:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[placement_database]
connection = mysql+pymysql://placement:password@192.168.1.40/placement
EOF

chmod 640 /etc/placement/placement.conf
chgrp placement /etc/placement/placement.conf


su -s /bin/bash placement -c "placement-manage db sync"
su -s /bin/bash nova -c "nova-manage api_db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 map_cell0"
su -s /bin/bash nova -c "nova-manage db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 create_cell --name cell1"
systemctl restart apache2
systemctl restart nova-*

openstack compute service list

echo "###################Install and Config Cinder###################"

openstack user create --domain default --project service --password servicepassword cinder
openstack role add --project service --user cinder admin
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3

openstack endpoint create --region RegionOne volumev3 public http://192.168.1.40:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://192.168.1.40:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://192.168.1.40:8776/v3/%\(tenant_id\)s

apt -y install cinder-api cinder-scheduler python3-cinderclient cinder-volume python3-mysqldb python3-rtslib-fb
apt -y install tgt thin-provisioning-tools

mv /etc/cinder/cinder.conf /etc/cinder/cinder.conf.org

projectID=$(openstack project list | grep service | awk '{print $2}')
userID=$(openstack user list | grep cinder | awk '{print $2}')

cat << EOF > /etc/cinder/cinder.conf
[DEFAULT]
my_ip = 192.168.1.40
rootwrap_config = /etc/cinder/rootwrap.conf
api_paste_confg = /etc/cinder/api-paste.ini
state_path = /var/lib/cinder
auth_strategy = keystone
transport_url = rabbit://openstack:password@192.168.1.40
enable_v3_api = True
cinder_internal_tenant_project_id = $projectID
cinder_internal_tenant_user_id = $userID
glance_api_servers = http://192.168.1.40:9292
enabled_backends = lvm

[database]
connection = mysql+pymysql://cinder:password@192.168.1.40/cinder

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.40:5000
auth_url = http://192.168.1.40:5000
memcached_servers = 192.168.1.40:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = servicepassword

[lvm]
image_volume_cache_enabled = True
image_volume_cache_max_size_gb = 0
image_volume_cache_max_count = 0
target_helper = tgtadm
target_protocol = iscsi
target_ip_address = 192.168.1.40
volume_group = vg_volume01
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volumes_dir = $state_path/volumes

[oslo_concurrency]
lock_path = $state_path/tmp
EOF

chmod 640 /etc/cinder/cinder.conf
chgrp cinder /etc/cinder/cinder.conf
su -s /bin/bash cinder -c "cinder-manage db sync"
pvcreate /dev/sdb
vgcreate vg_volume01 /dev/sdb
systemctl restart cinder-scheduler cinder-volume tgt

source ~/keystonerc
systemctl restart apache2
openstack volume service list

systemctl restart openstack-cinder-*

echo "###################Install and Config Horizon###################"

apt -y install openstack-dashboard

cat << EOF > /etc/apache2/conf-available/openstack-dashboard.conf
<VirtualHost *:80>
  WSGIScriptAlias /horizon /usr/share/openstack-dashboard/openstack_dashboard/wsgi.py process-group=horizon
  WSGIDaemonProcess horizon user=horizon group=horizon processes=3 threads=10 display-name=%{GROUP}
  WSGIProcessGroup horizon
  WSGIApplicationGroup %{GLOBAL}

  Alias /static /var/lib/openstack-dashboard/static/
  Alias /horizon/static /var/lib/openstack-dashboard/static/

  RedirectMatch "^/$" "/horizon/"

  <Directory />
    Options FollowSymLinks
    AllowOverride None
  </Directory>

  <Directory /usr/share/openstack-dashboard/openstack_dashboard>
    Require all granted
  </Directory>

  <Directory /var/lib/openstack-dashboard/static>
    Require all granted
  </Directory>

</VirtualHost>
EOF

sed -i '/^OPENSTACK_HOST/d' /etc/openstack-dashboard/local_settings.py
sed -i '/^OPENSTACK_KEYSTONE_URL/d' /etc/openstack-dashboard/local_settings.py
sed -i -e "s/ubuntu/default/g" /etc/openstack-dashboard/local_settings.py
cat << EOF >> /etc/openstack-dashboard/local_settings.py
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
        'LOCATION': '192.168.1.40:11211',
    },
}
SESSION_ENGINE = "django.contrib.sessions.backends.cache"
OPENSTACK_HOST = "192.168.1.40"
OPENSTACK_KEYSTONE_URL = "http://192.168.1.40:5000/v3"
#OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'Default'
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "volume": 3,
    "compute": 2,
}
EOF

systemctl restart apache2.service memcached.service

echo "###################Install and Config Neutron on Controller###################"

openstack user create --domain default --project service --password servicepassword neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking service" network
openstack endpoint create --region RegionOne network public http://192.168.1.40:9696
openstack endpoint create --region RegionOne network internal http://192.168.1.40:9696
openstack endpoint create --region RegionOne network admin http://192.168.1.40:9696

apt -y install neutron-server neutron-plugin-ml2 neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent python3-neutronclient

mv /etc/neutron/neutron.conf /etc/neutron/neutron.conf.org
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
dhcp_agent_notification = True
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
transport_url = rabbit://openstack:password@192.168.1.60

[agent]
root_helper = sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.60:5000
auth_url = http://192.168.1.60:5000
memcached_servers = 192.168.1.60:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

[database]
connection = mysql+pymysql://neutron:password@192.168.1.60/neutron_ml2

[nova]
auth_url = http://192.168.1.60:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = servicepassword

[oslo_concurrency]
lock_path = $state_path/tmp
EOF

chmod 640 /etc/neutron/neutron.conf
chgrp neutron /etc/neutron/neutron.conf

sed -i '/\[DEFAULT\]/a interface_driver = openvswitch\ndhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\nenable_isolated_metadata = true' /etc/neutron/dhcp_agent.ini
sed -i '/\[DEFAULT\]/a nova_metadata_host = 192.168.1.40\nmetadata_proxy_shared_secret = metadata_secret' /etc/neutron/metadata_agent.ini
sed -i '/\[cache\]/a memcache_servers = 192.168.1.40:11211' /etc/neutron/metadata_agent.ini

sed -i '/\[DEFAULT\]/a type_drivers = flat\ntenant_network_types =\nmechanism_drivers = openvswitch\nextension_drivers = port_security'  /etc/neutron/plugins/ml2/ml2_conf.ini
sed -i '/\[ml2_type_flat\]/a flat_networks = provider'  /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i '/\[ovs\]/a bridge_mappings = provider:br-ex' /etc/neutron/plugins/ml2/openvswitch_agent.ini
sed -i '/\[securitygroup\]/a firewall_driver = openvswitch\nenable_security_group = true\nenable_ipset = true' /etc/neutron/plugins/ml2/openvswitch_agent.ini

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

su -s /bin/bash neutron -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head"

cat << EOF > /etc/systemd/network/ens34.network
[Match]
Name=ens34

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF

systemctl restart systemd-networkd

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ens34

systemctl restart neutron-*

openstack network agent list

projectID=$(openstack project list | grep service | awk '{print $2}')
openstack network create --project $projectID --share --external --provider-network-type flat --provider-physical-network provider public
openstack subnet create subnet_public --network public --project $projectID --subnet-range 192.168.1.0/24 --allocation-pool start=192.168.1.200,end=192.168.1.254 --gateway 192.168.1.1 --dns-nameserver 8.8.8.8

openstack network list
openstack subnet list

echo "################### DONE ###################"
