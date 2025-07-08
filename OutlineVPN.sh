#!/bin/bash
## OS: "centos9","debian11","ubuntu2004","Ubuntu22.04","ubuntu2204","debian12","ubuntu2404"

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
# tags: ubuntu2004,ubuntu20.04,ubuntu-20.04,ubuntu2204,centos9,ubuntu22.04,debian10,debian11
RNAME=Outline
set -x
LOG_PIPE=/tmp/log.pipe.$$
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}
tee < ${LOG_PIPE} ${LOG_FILE} &
exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

cd /root/

#обновляем систему и ставим пакетики
## DS-689
if [ -f /root/outline_access_token ]; then
exit 0
fi
##

sleep 5

if [ -f /etc/redhat-release ]; then
  OSNAME=centos
else
  OSNAME=debian
fi

if [ "${OSNAME}" = "debian" ]; then
  #sudo dpkg --configure -a
  #temporary fix for resolve issue on ubuntu 22.04
  if grep -q -i 'ubuntu.*22.04' /etc/os-release; then
    echo 'DNS=1.1.1.1 8.8.8.8' >> /etc/systemd/resolved.conf 
    systemctl restart systemd-resolved
  fi
  apt update
  apt-mark hold qemu-guest-agent
  apt -y upgrade
  apt install curl wget -y
else
  yum install -y yum-versionlock || yum install -y 'dnf-command(versionlock)'
  yum versionlock qemu-guest-agent
  yum update -y
  yum install curl openssl wget -y
fi

#installing docker and outline
curl -s -k https://get.docker.com/ | sh
sleep 3
[ "${OSNAME}" = "centos" ] && systemctl enable --now docker
#echo '31.222.238.199 stark-industries.solutions' >> /etc/hosts
bash -c "$(wget --no-check-certificate -qO- https://the.hosting/outline/install_server.sh)" | tee -a outline_install.log
#sed -i '/31.222.238.199/d' /etc/hosts

if [ "${OSNAME}" = "centos" ]; then
  firewall-cmd --add-port $(grep 'Management port' /root/outline_install.log | awk '{print $4}' | tr -d ',')/tcp --permanent
  ACCESS_KEY_PORT=$(grep 'Access key port' /root/outline_install.log | awk '{print $5}' | tr -d ',')
  firewall-cmd --add-port $ACCESS_KEY_PORT/tcp --permanent
  firewall-cmd --add-port $ACCESS_KEY_PORT/udp --permanent
  firewall-cmd --reload
fi


# for cases, when user intall it on a non-clean installed Ubuntu, which have ufw
if grep -q -i 'ubuntu.*22.04' /etc/os-release && [ -f /usr/sbin/ufw ]; then
    MANAGEMENT_PORT=$(grep 'Management port' /root/outline_install.log | awk '{print $4}' | tr -d ',')
    ACCESS_KEY_PORT=$(grep 'Access key port' /root/outline_install.log | awk '{print $5}' | tr -d ',')
    ufw allow $MANAGEMENT_PORT/tcp
    ufw allow $ACCESS_KEY_PORT/tcp
    ufw allow $ACCESS_KEY_PORT/udp
    ufw allow 1024:65535/tcp
    ufw allow 1024:65535/udp
fi

grep 'apiUrl' outline_install.log | sed -r "s/\\x1B\\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" > outline_access_token

if [ "${OSNAME}" = "debian" ]; then
  #добавляем цветное motd сообщение с доступами к панели
  cat > /etc/update-motd.d/94-outline << 'EOF2'
#!/bin/bash
export TERM=xterm-256color
echo "$(tput setaf 10)
===================== Outline VPN ======================
Outline access token: $(cat /root/outline_access_token)
========================================================
$(tput sgr0)"
EOF2
  chmod +x /etc/update-motd.d/94-outline
else
  cat >> /root/.bash_profile << 'EOF2'
export TERM=xterm-256color
echo "$(tput setaf 10)
===================== Outline VPN ======================
Outline access token: $(cat /root/outline_access_token)
========================================================
$(tput sgr0)"
EOF2
fi

#sysctl tuning
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

outline_access_token=$(cat /root/outline_access_token)
vm_export_variable output_token "$outline_access_token" || :