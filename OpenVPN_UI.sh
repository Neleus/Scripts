#!/bin/sh
vm_export_variable() {
    echo "vm6_variable $1='$(echo -n $2 | base64 -w 0)'";
}
vm_export_file() {
    local file_size=$(stat -c %s $2);

    if [ $file_size -ge 2097152 ]; then
        echo "vm6_file $1='size_error'";
    else
        echo "vm6_file $1='$(base64 -w 0 $2)'";
    fi
}
vm_export_dir() {
    TEMP=$(mktemp /tmp/temporary-file.XXXXXXXX);
    tar -czf $TEMP "$2";
    file_size=$(stat -c %s $TEMP);
    if [ $file_size -ge 2097152 ]; then
        echo "vm6_file $1='size_error'";
    else
        echo "vm6_dir $1='$(base64 -w 0 $TEMP)'";
    fi
    rm -f $TEMP;
}
# tags: ubuntu2004,ubuntu20.04,ubuntu2204
RNAME=OpenVPN
set -x
LOG_PIPE=/tmp/log.pipe.$$
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}
tee < ${LOG_PIPE} ${LOG_FILE} &
exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

sleep 5

if [ -f /etc/redhat-release ]; then
  OSNAME=centos
  OSREL=$(printf '%.0f' $(rpm -qf --qf '%{version}' /etc/redhat-release))
else
  OSNAME=debian
  which lsb_release 2>/dev/null || apt-get -y install lsb_release
  DEB_VERSION=$(lsb_release -r -s)
  DEB_MAJOR_VERSION=$(echo ${DEB_VERSION} | awk -F'.' '{print $1}')
  DEB_FAMILY=$(lsb_release -s -i)
fi

if [ "${OSNAME}" = "debian" ]; then
  echo "deb [trusted=yes] https://cad.github.io/ovpm/deb/ ovpm main" >> /etc/apt/sources.list
  export DEBIAN_FRONTEND="noninteractive"
  apt update
  apt-mark hold qemu-guest-agent
  # apt -y upgrade
  apt install -y ovpm pwgen iptables
else
  yum -x qemu-guest-agent update -y
  yum install yum-utils epel-release -y
  yum-config-manager --add-repo https://cad.github.io/ovpm/rpm/ovpm.repo
  yum install ovpm pwgen iptables openssl -y
  firewall-cmd --add-port 8080/tcp --permanent
  firewall-cmd --add-port 1197/udp --permanent
  firewall-cmd --add-masquerade --permanent
  firewall-cmd --reload
fi

systemctl start ovpmd
systemctl enable ovpmd

sleep 3

echo y | ovpm vpn init --hostname 45.14.246.35

pass=""
if [ -z $pass ]; then pass=$(pwgen 20 -n1); fi

ovpm user create -u admin -p $pass
ovpm user update -u admin --admin
ovpm user update -u admin -p $pass

cat > /etc/sysctl.conf << TUNES
net.core.netdev_max_backlog=30000
net.core.somaxconn=65535
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog = 720000
net.ipv4.tcp_max_tw_buckets = 720000
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_fin_timeout = 60
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 9
net.ipv4.tcp_keepalive_intvl = 75
net.core.wmem_max = 134217728
net.core.rmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 65536 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_moderate_rcvbuf =1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_congestion_control=htcp
net.netfilter.nf_conntrack_max = 134217728
net.nf_conntrack_max = 134217728
net.ipv4.ip_forward=1
TUNES
sysctl -p /etc/sysctl.conf

vm_export_variable output_pass "$pass" || :