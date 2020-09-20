#!/bin/bash -ex

echo "###################Update package and add Repo Ussuri###################"
yum -y update
yum install -y epel-release
dnf -y install centos-release-openstack-ussuri
sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-OpenStack-ussuri.repo
dnf --enablerepo=centos-openstack-ussuri -y upgrade

echo "###################Install and Config MariaDB###################"

dnf module -y install mariadb:10.3

cat << EOF > /etc/my.cnf.d/charaset.cnf
[mysqld]
character-set-server = utf8mb4

[client]
default-character-set = utf8mb4
EOF

systemctl enable --now mariadb

sed -i '/\[mysqld\]/a max_connections=500' /etc/my.cnf.d/mariadb-server.cnf

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

echo "###################Install and Config RabbitMQ && Memcached###################"

dnf --enablerepo=PowerTools -y install rabbitmq-server memcached

cat << EOF > /etc/sysconfig/memcached
PORT="11211"
USER="memcached"
MAXCONN="1024"
CACHESIZE="64"
OPTIONS="-l 0.0.0.0,::"
EOF

systemctl restart mariadb rabbitmq-server memcached
systemctl enable mariadb rabbitmq-server memcached

rabbitmqctl add_user openstack password
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

echo "###################Install and Config Keystone###################"

dnf --enablerepo=centos-openstack-ussuri,epel,PowerTools -y install openstack-keystone python3-openstackclient httpd mod_ssl python3-mod_wsgi python3-oauth2client

sed -i '/\[cache\]/a memcache_servers = 192.168.1.50:11211' /etc/keystone/keystone.conf
sed -i '/\[database\]/a connection = mysql+pymysql://keystone:password@localhost/keystone' /etc/keystone/keystone.conf
sed -i -e "s/#provider = fernet/provider = fernet/g" /etc/keystone/keystone.conf

su -s /bin/bash keystone -c "keystone-manage db_sync"

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password adminpassword --bootstrap-admin-url http://192.168.1.50:5000/v3/ --bootstrap-internal-url http://192.168.1.50:5000/v3/ --bootstrap-public-url http://192.168.1.50:5000/v3/ --bootstrap-region-id RegionOne

ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
systemctl enable --now httpd

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
openstack endpoint create --region RegionOne image public http://192.168.1.50:9292
openstack endpoint create --region RegionOne image internal http://192.168.1.50:9292
openstack endpoint create --region RegionOne image admin http://192.168.1.50:9292

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-glance
mv /etc/glance/glance-api.conf /etc/glance/glance-api.conf.org

cat << EOF > /etc/glance/glance-api.conf
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/

[database]
connection = mysql+pymysql://glance:password@192.168.1.50/glance

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.50:5000
auth_url = http://192.168.1.50:5000
memcached_servers = 192.168.1.50:11211
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
systemctl enable --now openstack-glance-api

echo "###################Install and Config Nova on Controller###################"

openstack user create --domain default --project service --password servicepassword nova
openstack role add --project service --user nova admin

openstack user create --domain default --project service --password servicepassword placement
openstack role add --project service --user placement admin

openstack service create --name nova --description "OpenStack Compute service" compute
openstack service create --name placement --description "OpenStack Compute Placement service" placement

openstack endpoint create --region RegionOne compute public http://192.168.1.50:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://192.168.1.50:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute admin http://192.168.1.50:8774/v2.1/%\(tenant_id\)s

openstack endpoint create --region RegionOne placement public http://192.168.1.50:8778
openstack endpoint create --region RegionOne placement internal http://192.168.1.50:8778
openstack endpoint create --region RegionOne placement admin http://192.168.1.50:8778

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-nova openstack-placement-api

mv /etc/nova/nova.conf /etc/nova/nova.conf.org
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
my_ip = 192.168.1.50
state_path = /var/lib/nova
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
transport_url = rabbit://openstack:password@192.168.1.50

use_neutron = True
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver
firewall_driver = nova.virt.firewall.NoopFirewallDriver
vif_plugging_is_fatal = True
vif_plugging_timeout = 300

[api]
auth_strategy = keystone

[glance]
api_servers = http://192.168.1.50:9292

[cinder]
os_region_name = RegionOne

[neutron]
auth_url = http://192.168.1.50:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = servicepassword
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret

[oslo_concurrency]
lock_path = $state_path/tmp

[api_database]
connection = mysql+pymysql://nova:password@192.168.1.50/nova_api

[database]
connection = mysql+pymysql://nova:password@192.168.1.50/nova

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.50:5000
auth_url = http://192.168.1.50:5000
memcached_servers = 192.168.1.50:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[placement]
auth_url = http://192.168.1.50:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

sed -i -e 's\lock_path = /tmp\lock_path = $state_path/tmp\g' /etc/nova/nova.conf

chmod 640 /etc/nova/nova.conf
chgrp nova /etc/nova/nova.conf

mv /etc/placement/placement.conf /etc/placement/placement.conf.org
cat << EOF > /etc/placement/placement.conf
[DEFAULT]
debug = false

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.50:5000
auth_url = http://192.168.1.50:5000
memcached_servers = 192.168.1.50:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[placement_database]
connection = mysql+pymysql://placement:password@192.168.1.50/placement
EOF

chmod 640 /etc/placement/placement.conf
chgrp placement /etc/placement/placement.conf

cat << EOF > /etc/httpd/conf.d/00-placement-api.conf
Listen 8778

<VirtualHost *:8778>
  WSGIProcessGroup placement-api
  WSGIApplicationGroup %{GLOBAL}
  WSGIPassAuthorization On
  WSGIDaemonProcess placement-api processes=3 threads=1 user=placement group=placement
  WSGIScriptAlias / /usr/bin/placement-api
  <IfVersion >= 2.4>
    ErrorLogFormat "%M"
  </IfVersion>
  ErrorLog /var/log/placement/placement-api.log
  #SSLEngine On
  #SSLCertificateFile ...
  #SSLCertificateKeyFile ...
  <Directory /usr/bin>
    Require all granted
  </Directory>
</VirtualHost>

Alias /placement-api /usr/bin/placement-api
<Location /placement-api>
  SetHandler wsgi-script
  Options +ExecCGI
  WSGIProcessGroup placement-api
  WSGIApplicationGroup %{GLOBAL}
  WSGIPassAuthorization On
</Location>
EOF

su -s /bin/bash placement -c "placement-manage db sync"
su -s /bin/bash nova -c "nova-manage api_db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 map_cell0"
su -s /bin/bash nova -c "nova-manage db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 create_cell --name cell1"
systemctl restart httpd
chown placement. /var/log/placement/placement-api.log
systemctl enable --now openstack-nova-api openstack-nova-conductor openstack-nova-scheduler openstack-nova-novncproxy
systemctl restart openstack-nova-*

openstack compute service list

echo "###################Install and Config Neutron on Controller###################"

openstack user create --domain default --project service --password servicepassword neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking service" network
openstack endpoint create --region RegionOne network public http://192.168.1.50:9696
openstack endpoint create --region RegionOne network internal http://192.168.1.50:9696
openstack endpoint create --region RegionOne network admin http://192.168.1.50:9696

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

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
transport_url = rabbit://openstack:password@192.168.1.50

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.50:5000
auth_url = http://192.168.1.50:5000
memcached_servers = 192.168.1.50:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

[database]
connection = mysql+pymysql://neutron:password@192.168.1.50/neutron_ml2

[nova]
auth_url = http://192.168.1.50:5000
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

sed -i -e 's\lock_path = /tmp\lock_path = $state_path/tmp\g' /etc/neutron/neutron.conf

chmod 640 /etc/neutron/neutron.conf
chgrp neutron /etc/neutron/neutron.conf

sed -i '/\[DEFAULT\]/a interface_driver = openvswitch\ndhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\nenable_isolated_metadata = true' /etc/neutron/dhcp_agent.ini
sed -i '/\[DEFAULT\]/a nova_metadata_host = 192.168.1.50\nmetadata_proxy_shared_secret = metadata_secret' /etc/neutron/metadata_agent.ini
sed -i '/\[cache\]/a memcache_servers = 192.168.1.50:11211' /etc/neutron/metadata_agent.ini

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

systemctl enable --now openvswitch
ovs-vsctl add-br br-int
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/bash neutron -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head"
systemctl enable --now neutron-server neutron-dhcp-agent neutron-metadata-agent neutron-openvswitch-agent
systemctl restart openstack-neutron-*

openstack network agent list

ovs-vsctl add-br br-ex
ovs-vsctl add-port br-ex ens34

systemctl restart neutron-openvswitch-agent

projectID=$(openstack project list | grep service | awk '{print $2}')
openstack network create --project $projectID --share --external --provider-network-type flat --provider-physical-network provider public
openstack subnet create subnet_public --network public --project $projectID --subnet-range 192.168.1.0/24 --allocation-pool start=192.168.1.200,end=192.168.1.254 --gateway 192.168.1.1 --dns-nameserver 8.8.8.8

openstack network list
openstack subnet list

echo "###################Install and Config Cinder###################"

openstack user create --domain default --project service --password servicepassword cinder
openstack role add --project service --user cinder admin
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3

openstack endpoint create --region RegionOne volumev3 public http://192.168.1.50:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://192.168.1.50:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://192.168.1.50:8776/v3/%\(tenant_id\)s

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-cinder targetcli

mv /etc/cinder/cinder.conf /etc/cinder/cinder.conf.org

projectID=$(openstack project list | grep service | awk '{print $2}')
userID=$(openstack user list | grep cinder | awk '{print $2}')

cat << EOF > /etc/cinder/cinder.conf
[DEFAULT]
my_ip = 192.168.1.50
log_dir = /var/log/cinder
state_path = /var/lib/cinder
auth_strategy = keystone
transport_url = rabbit://openstack:password@192.168.1.50
glance_api_servers = http://192.168.1.50:9292
enable_v3_api = True
enabled_backends = lvm
cinder_internal_tenant_project_id = $projectID
cinder_internal_tenant_user_id = $userID

[database]
connection = mysql+pymysql://cinder:password@192.168.1.50/cinder

[keystone_authtoken]
www_authenticate_uri = http://192.168.1.50:5000
auth_url = http://192.168.1.50:5000
memcached_servers = 192.168.1.50:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = servicepassword

[oslo_concurrency]
lock_path = $state_path/tmp

[lvm]
image_volume_cache_enabled = True
image_volume_cache_max_size_gb = 0
image_volume_cache_max_count = 0
target_helper = lioadm
target_protocol = iscsi
target_ip_address = 192.168.1.50
volume_group = vg_volume01
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volumes_dir = $state_path/volumes
EOF

sed -i -e 's\volumes_dir = /volumes\volumes_dir = $state_path/volumes\g' /etc/cinder/cinder.conf
sed -i -e 's\lock_path = /tmp\lock_path = $state_path/tmp\g' /etc/cinder/cinder.conf

chmod 640 /etc/cinder/cinder.conf
chgrp cinder /etc/cinder/cinder.conf
su -s /bin/bash cinder -c "cinder-manage db sync"
systemctl enable --now cinder-scheduler.service cinder-volume.service

source ~/keystonerc
systemctl restart httpd
openstack volume service list

pvcreate /dev/sdb
vgcreate vg_volume01 /dev/sdb

systemctl restart cinder-scheduler.service cinder-volume.service


echo "###################Install and Config Horizon###################"

dnf --enablerepo=centos-openstack-ussuri,PowerTools,epel -y install openstack-dashboard

sed -i '/AllowOverride none/i Options FollowSymLinks' /etc/httpd/conf/httpd.conf

cat << EOF > /etc/httpd/conf.d/openstack-dashboard.conf
<VirtualHost *:80>
  WSGIDaemonProcess dashboard
  WSGIProcessGroup dashboard
  WSGIApplicationGroup %{GLOBAL}
  WSGIScriptAlias /dashboard /usr/share/openstack-dashboard/openstack_dashboard/wsgi/django.wsgi
  Alias /dashboard/static /usr/share/openstack-dashboard/static

  RedirectMatch "^/$" "/dashboard/"

  <Directory />
    Options FollowSymLinks
    AllowOverride None
  </Directory>

  <Directory /usr/share/openstack-dashboard/openstack_dashboard/wsgi>
    Options All
    AllowOverride All
    Require all granted
  </Directory>

  <Directory /usr/share/openstack-dashboard/static>
    Options All
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
WSGISocketPrefix run/wsgi
EOF

sed -i '/^ALLOWED_HOSTS/d' /etc/openstack-dashboard/local_settings
sed -i '/^OPENSTACK_HOST/d' /etc/openstack-dashboard/local_settings
sed -i '/^OPENSTACK_KEYSTONE_URL/d' /etc/openstack-dashboard/local_settings
cat << EOF >> /etc/openstack-dashboard/local_settings
ALLOWED_HOSTS = ['*']
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
        'LOCATION': '192.168.1.50:11211',
    },
}
SESSION_ENGINE = "django.contrib.sessions.backends.cache"
OPENSTACK_HOST = "192.168.1.50"
OPENSTACK_KEYSTONE_URL = "http://192.168.1.50:5000/v3"
WEBROOT = '/dashboard/'
LOGIN_URL = '/dashboard/auth/login/'
LOGOUT_URL = '/dashboard/auth/logout/'
LOGIN_REDIRECT_URL = '/dashboard/'
#OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'Default'
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "volume": 3,
    "compute": 2,
}
EOF

systemctl restart memcached httpd

echo "################### DONE ###################"
