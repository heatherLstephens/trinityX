#!/bin/bash

######################################################################
# TrinityX
# Copyright (c) 2016  ClusterVision B.V.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License (included with the sources) for more
# details.
######################################################################

if [ "x${LUNA_MONGO_PASS}" = "x" ]; then
    LUNA_MONGO_PASS=`get_password $LUNA_MONGO_PASS`
    store_password LUNA_MONGO_PASS $LUNA_MONGO_PASS
fi

MONGO_HOST=localhost
if flag_is_set HA; then
    MONGO_HOST=luna/localhost
fi

function replace_template() {
    [ $# -gt 3 -o $# -lt 2 ] && echo "Wrong numger of argument in replace_template." && exit 1
    if [ $# -eq 3 ]; then
        FROM=${1}
        TO=${2}
        FILE=${3}
    fi
    if [ $# -eq 2 ]; then
        FROM=${1}
        TO=${!FROM}
        FILE=${2}
    fi
    sed -i -e "s/{{ ${FROM} }}/${TO//\//\\/}/g" $FILE
}

function get_lpath() {
    # get luna homedir
    U=$1
    if [ "x${U}" = "x" ]; then
        U="luna"
    fi
    eval echo ~${U}
}

function luna_versionlock() {
    /usr/bin/yum versionlock luna-*
}

function setup_tftp() {
    echo_info "Setup tftp."

    /usr/bin/mkdir -p /tftpboot
    /usr/bin/sed -e 's/^\(\W\+disable\W\+\=\W\)yes/\1no/g' -i /etc/xinetd.d/tftp
    /usr/bin/sed -e 's|^\(\W\+server_args\W\+\=\W-s\W\)/var/lib/tftpboot|\1/tftpboot|g' -i /etc/xinetd.d/tftp
    [ -f /tftpboot/luna_undionly.kpxe ] || cp /usr/share/ipxe/undionly.kpxe /tftpboot/luna_undionly.kpxe

    flag_is_set SELINUX && restorecon -Rv /tftpboot/
}

function setup_dns() {
    echo_info "Setup DNS."
    /usr/bin/rm -rf /var/named/*luna*
    /usr/bin/rm -rf /etc/named.luna.zones
    /usr/bin/touch /etc/named.luna.zones

    append_line /etc/named.conf "include \"/etc/named.luna.zones\";"
}

function setup_dns_secondary() {
    echo_info "Setup DNS."
    /usr/bin/touch /etc/named.luna.zones
    append_line /etc/named.conf "include \"/etc/named.luna.zones\";"
}

function setup_nginx() {

    LPATH=$(get_lpath)

    echo_info "Setup nginx."

    /usr/bin/cp ${POST_FILEDIR}/nginx.conf /etc/nginx/
    /usr/bin/mkdir -p /etc/nginx/conf.d/
    /usr/bin/cp ${POST_FILEDIR}/nginx-luna.conf /etc/nginx/conf.d/
    replace_template LPATH /etc/nginx/conf.d/nginx-luna.conf
    flag_is_set SELINUX && semanage port -a -t http_port_t  -p tcp 7050
    flag_is_set SELINUX && setsebool httpd_can_network_connect 1 -P
}

function create_mongo_user() {
    echo_info "Configure credentials for MongoDB access."
    /usr/bin/mongo --host ${MONGO_HOST} -u "root" -p${MONGODB_ROOT_PASS} --authenticationDatabase admin << EOF
use luna
db.createUser({user: "luna", pwd: "${LUNA_MONGO_PASS}", roles: [{role: "dbOwner", db: "luna"}]})
EOF
}

function configure_mongo_credentials() {
    echo_info "Create /etc/luna.conf"
    if flag_is_set HA; then
        /usr/bin/cat > /etc/luna.conf <<EOF
[MongoDB]
replicaset=luna
server=localhost
authdb=luna
user=luna
password=${LUNA_MONGO_PASS}
EOF
    else
        /usr/bin/cat > /etc/luna.conf <<EOF
[MongoDB]
server=localhost
authdb=luna
user=luna
password=${LUNA_MONGO_PASS}
EOF
    fi
    /usr/bin/chown luna:luna /etc/luna.conf
    /usr/bin/chmod 600 /etc/luna.conf
}

function configure_luna() {

    LPATH=$(get_lpath)

    /usr/bin/chown luna:luna $LPATH

    create_luna_db_backup
    echo -e "use luna\ndb.dropDatabase()" | /usr/bin/mongo -u "root" -p${MONGODB_ROOT_PASS} --authenticationDatabase admin --host ${MONGO_HOST}
    if ! /usr/sbin/luna cluster init --path $LPATH --frontend_address ${LUNA_FRONTEND}; then
        echo_error "Luna is unable to initialize cluster"
        exit 1
    fi
    /usr/sbin/luna network add -n ${LUNA_NETWORK_NAME} -N ${LUNA_NETWORK} -P ${LUNA_PREFIX}
    /usr/sbin/luna network change ${LUNA_NETWORK_NAME} --ns_ip ${LUNA_FRONTEND} --ns_hostname ${TRIX_CTRL_HOSTNAME}
}

function create_luna_db_backup() {
    SUFFIX="trixbkp.$(/usr/bin/date +%Y-%m-%d_%H-%M-%S)"
    BKPPATH=/root/mongo.luna.${SUFFIX}
    echo_info "Create Luna DB backup to ${BKPPATH}."
    /usr/bin/mongodump -u "root" -p${MONGODB_ROOT_PASS} --authenticationDatabase admin --host ${MONGO_HOST} -d luna -o ${BKPPATH}

}

function configure_dns_dhcp() {

    echo_info "Configure DNS and DHCP."

    if ! /usr/sbin/luna cluster makedhcp -N ${LUNA_NETWORK_NAME} -s ${LUNA_DHCP_RANGE_START} -e ${LUNA_DHCP_RANGE_END}; then
        echo_error "Luna is unable to create dhcpd config."
        exit 1
    fi
    if ! /usr/sbin/luna cluster makedns; then
        echo_error "Luna is unable to create DNS config."
        exit 1
    fi
}

function copy_configs_to_trix_local() {
    /usr/bin/mkdir -p ${TRIX_LOCAL}/etc
    /usr/bin/mv /etc/named.luna.zones ${TRIX_LOCAL}/etc/

    /usr/bin/mkdir -p ${TRIX_SHARED}/etc/dhcp
    /usr/bin/mv /etc/dhcp/dhcpd.conf ${TRIX_SHARED}/etc/
}

function create_symlinks() {
    /usr/bin/ln -fs ${TRIX_LOCAL}/etc/named.luna.zones /etc/named.luna.zones
    /usr/bin/ln -fs ${TRIX_SHARED}/etc/dhcpd.conf /etc/dhcp/dhcpd.conf
}

function configure_pacemaker() {
    echo_info "Configure pacemaker's resources."
    TMPFILE=$(/usr/bin/mktemp -p /root pacemaker_luna.XXXX)
    /usr/sbin/pcs cluster cib ${TMPFILE}
    for SERVICE in dhcpd nginx lweb ltorrent; do
        /usr/sbin/pcs -f ${TMPFILE} resource delete ${SERVICE} 2>/dev/null || /usr/bin/true
        /usr/sbin/pcs -f ${TMPFILE} \
            resource create ${SERVICE} systemd:${SERVICE} --force --group=Luna
        /usr/sbin/pcs -f ${TMPFILE} resource update ${SERVICE} op monitor interval=0 # disable fail actions
    done
    # On failover mongo requires about 30 seconds to get quorum and find new primary node.
    # Systemd unit has 90 sec timeout. So systemd should report a failure, not pacemaker.
    # Fix for https://github.com/clustervision/trinityX/issues/201
    /usr/sbin/pcs -f ${TMPFILE} resource update ltorrent op start timeout=120
    /usr/sbin/pcs -f ${TMPFILE} resource update lweb     op start timeout=120
    /usr/sbin/pcs cluster cib-push ${TMPFILE}

}

function install_standalone() {
    /usr/bin/systemctl stop dhcpd xinetd nginx 2>/dev/null || /usr/bin/true
    /usr/bin/systemctl stop lweb ltorrent 2>/dev/null || /usr/bin/true
    luna_versionlock
    setup_tftp
    setup_dns
    setup_nginx
    create_mongo_user
    configure_mongo_credentials
    configure_luna
    configure_dns_dhcp
    if ! /usr/bin/systemctl start lweb ltorrent; then
        echo_error "Unable to start Luna services."
        exit 1
    fi
    if ! /usr/bin/systemctl start dhcpd xinetd nginx; then
        echo_error "Unable to start services."
        exit 1
    fi
    /usr/bin/systemctl enable dhcpd xinetd nginx lweb ltorrent
}

function install_primary() {
    install_standalone
    /usr/bin/systemctl disable nginx dhcpd lweb ltorrent
    /usr/bin/systemctl stop dhcpd lweb ltorrent || /usr/bin/true
    copy_configs_to_trix_local
    create_symlinks
    if ! /usr/bin/systemctl start dhcpd lweb ltorrent; then
        echo_error "Unable to start services"
    fi
    configure_pacemaker
}

function install_secondary() {
    /usr/bin/systemctl stop dhcpd lweb ltorrent 2>/dev/null || /usr/bin/true
    luna_versionlock
    setup_tftp
    setup_dns_secondary
    setup_nginx
    create_system_local_dirs
    configure_mongo_credentials 1
    /usr/bin/systemctl start xinetd nginx
    /usr/bin/systemctl enable xinetd nginx
    /usr/bin/systemctl disable nginx dhcpd lweb ltorrent
    create_symlinks
}

if flag_is_unset HA; then
    install_standalone
else
    if flag_is_set PRIMARY_INSTALL; then
        install_primary
    else
        install_secondary
    fi
fi

