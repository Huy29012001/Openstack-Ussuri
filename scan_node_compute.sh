#!/bin/bash

source ~/keystonerc

su -s /bin/bash nova -c "nova-manage cell_v2 discover_hosts"

openstack compute service list