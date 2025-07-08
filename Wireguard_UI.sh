#!/bin/sh
## OS: "debian11","ubuntu2204","ubuntu2404","alma9","centos9","debian12"

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
# tags: ubuntu2004,ubuntu20.04,ubuntu2204,alma8,debian10,debian11
RNAME=Wireguard
set -x
LOG_PIPE=/tmp/log.pipe.$$
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}
tee < ${LOG_PIPE} ${LOG_FILE} &
exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

#обновляем пакетики и ставим wireguard
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
  if [ "${DEB_FAMILY}" = Debian -a "${DEB_VERSION}" = 10 ]; then
    echo 'deb http://deb.debian.org/debian buster-backports main' >> /etc/apt/sources.list.d/backports.list
  fi
  export DEBIAN_FRONTEND="noninteractive"
  apt update
  apt-mark hold qemu-guest-agent
  apt -y upgrade
  apt -y install wireguard wget curl pwgen jq iptables
else
  yum -x qemu-guest-agent update -y
  yum install elrepo-release epel-release -y
  if [ "${OSREL}" -gt 7 ]; then
    yum install --nobest kmod-wireguard -y
    yum install wireguard-tools wget curl pwgen jq tar -y
  else
    yum install kmod-wireguard wireguard-tools wget curl pwgen jq tar -y
  fi
fi

#echo '31.222.238.199 stark-industries.solutions' >> /etc/hosts
wget -O /root/wireguard-ui --no-check-certificate "http://the.hosting/wireguard/wireguard-ui?from=vmmgr"
chmod +x /root/wireguard-ui
wget -O /root/db.tar.gz --no-check-certificate "http://the.hosting/wireguard/db.tar.gz?from=vmmgr"
tar -xvzf /root/db.tar.gz -C /root/
rm -f /root/db.tar.gz
#sed -i '/31.222.238.199/d' /etc/hosts

ip_addr=$(ip r get 1.1.1.1 | grep -Po "src \K\S+")
sed -i "s/REPLACE_ME/$ip_addr/g" /root/db/server/global_settings.json
if [ "$(ip -br a | grep $ip_addr | awk '{print $1}')" = eth0 ]; then
  sed -i "s/ens3/eth0/g" /root/db/server/interfaces.json
fi

SYSTEMCTL_BIN=$(whereis systemctl -b | awk '{print $2}')

touch /etc/systemd/system/wgui.service
cat << EOF > /etc/systemd/system/wgui.service
[Unit]
Description=Restart WireGuard
After=network.target

[Service]
Type=oneshot
ExecStart=${SYSTEMCTL_BIN} restart wg-quick@wg0.service

[Install]
RequiredBy=wgui.path
EOF

touch /etc/systemd/system/wgui.path
cat << EOF2 > /etc/systemd/system/wgui.path
[Unit]
Description=Watch /etc/wireguard/wg0.conf for changes

[Path]
PathModified=/etc/wireguard/wg0.conf

[Install]
WantedBy=multi-user.target
EOF2

touch /etc/systemd/system/wireguard-ui.service
cat << EOF3 > /etc/systemd/system/wireguard-ui.service
[Unit]
Description=Wireguard-UI
After=network.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/root/wireguard-ui
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=Wireguard-UI
User=root
Group=root
Environment=PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:/root/botShakes

[Install]
WantedBy=multi-user.target
EOF3

mkdir -pm 0700 /etc/wireguard/
touch /etc/wireguard/wg0.conf

#включаем форвардинг
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w "net.ipv4.ip_forward=1"

#устанавливаем пароль на веб интерфейс wireguard
pass=""
if [ -z $pass ]; then pass=$(pwgen 20 -n1); fi
sed -i "s/REPLACE_ME/$pass/g" /root/db/server/users.json

#запускаем службы
systemctl daemon-reload
systemctl enable --now wgui.path
systemctl enable --now wgui.service
systemctl enable --now wireguard-ui

#открываем порты в firewall
if [ "${OSNAME}" = "debian" ]; then
  which which 2>/dev/null || apt install -y which
  which ufw 2>/dev/null || apt install -y ufw
  if [ "$(ufw status | awk '{print $2}')" = inactive ]; then
    ufw --force enable
    ufw default allow FORWARD
    ufw allow ssh
  fi
  ufw allow 41194/udp
  ufw allow 5000/tcp
else
  firewall-cmd --permanent --add-port=41194/udp
  firewall-cmd --permanent --add-port=5000/tcp
  firewall-cmd --permanent --add-masquerade
  firewall-cmd --reload
fi

#выводим информацию о состоянии wireguard и его интерфейса
wg
ip a show wg0

if [ "${OSNAME}" = "debian" ]; then
  #добавляем цветное motd сообщение с доступами к панели
  cat > /etc/update-motd.d/93-wireguard << 'EOF2'
#!/bin/bash
export TERM=xterm-256color
ip_addr=$(cat /root/db/server/global_settings.json | jq -r '.endpoint_address')
username=$(cat /root/db/server/users.json | jq -r '.username')
password=$(cat /root/db/server/users.json | jq -r '.password')
echo "$(tput setaf 10)
===================== Wireguard UI =====================
URL: http://$ip_addr:5000/login
Login: $username
Password: $password
========================================================
Documentation: https://pq.hosting/help/pq_hosting_instructions/200-instrukcija-po-podkljucheniju-k-wireguard-vpn.html
$(tput sgr0)"
EOF2
  chmod +x /etc/update-motd.d/93-wireguard
else
  #В RH-дистрибутивы, в .bashrc (upd. todo .bash_profile)
  cat >> /root/.bash_profile << 'EOF2'
export TERM=xterm-256color
ip_addr=$(cat /root/db/server/global_settings.json | jq -r '.endpoint_address')
username=$(cat /root/db/server/users.json | jq -r '.username')
password=$(cat /root/db/server/users.json | jq -r '.password')
echo "$(tput setaf 10)
===================== Wireguard UI =====================
URL: http://$ip_addr:5000/login
Login: $username
Password: $password
========================================================
Documentation: https://pq.hosting/help/pq_hosting_instructions/200-instrukcija-po-podkljucheniju-k-wireguard-vpn.html
$(tput sgr0)"
EOF2
fi

if [ "${OSNAME}" = debian ]; then
  if [ "${DEB_FAMILY}" = Ubuntu ]; then
    if [ "${DEB_MAJOR_VERSION}" -lt 20 ]; then
      shutdown --no-wall -r
    fi
  else
    if [ "${DEB_MAJOR_VERSION}" -lt 11 ]; then
      shutdown --no-wall -r
    fi
  fi
else
  if [ "${OSREL}" = 8 ]; then
    shutdown --no-wall -r
  fi
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

vm_export_variable output_pass "$pass" || :