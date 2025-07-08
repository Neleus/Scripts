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
# tags: ubuntu2004,ubuntu2204,centos9
RNAME=3proxy
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
fi

if [ "${OSNAME}" = "debian" ]; then
    apt update
    apt-mark hold qemu-guest-agent
    apt install -y pwgen git jq ruby ruby-sinatra puma sudo

    wget https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.deb

    dpkg -i 3proxy-0.9.4.x86_64.deb

    chmod +w /usr/local/3proxy/conf
    chmod +w /usr/local/3proxy/conf/passwd
    sudo -u proxy touch /usr/local/3proxy/conf/tunnels

    gem install unix-crypt
else
    dnf -x qemu-guest-agent update -y

    if [ "${OSREL}" -eq 9 ]; then
        dnf config-manager --set-enabled crb
    fi

    dnf install -y epel-release epel-next-release
    dnf install -y pwgen git jq ruby wget

    wget https://github.com/3proxy/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.rpm
    rpm -i 3proxy-0.9.4.x86_64.rpm

    systemctl stop firewalld
    systemctl disable firewalld
    systemctl mask --now firewalld

    usermod -d /usr/local/3proxy proxy
    sudo -u proxy chmod +w /usr/local/3proxy/
    sudo -u proxy chmod +w /usr/local/3proxy/conf
    sudo -u proxy chmod +w /usr/local/3proxy/conf/passwd
    sudo -u proxy touch /usr/local/3proxy/conf/tunnels
    sudo -u proxy chmod +w /usr/local/3proxy/conf/tunnels
    sudo -u proxy mkdir /usr/local/3proxy/logs
    sudo -u proxy mkdir /usr/local/3proxy/count

    dnf group install "Development Tools" -y
    dnf install -y ruby-devel

    cd /tmp

    if [ "${OSREL}" -eq 8 ]; then
        sudo -uproxy gem install sinatra -v 2.2.4
    else
        sudo -uproxy gem install sinatra
    fi

    sudo -uproxy gem install unix-crypt puma
    sudo -uproxy gem install rackup puma
fi

# Current packages creates /var/run/3proxy but it does not persist on reboot
mkdir /usr/lib/systemd/system/3proxy.service.d
cat << EOF0 > /usr/lib/systemd/system/3proxy.service.d/3proxy.conf
[Service]
RuntimeDirectory=3proxy
EOF0

systemctl daemon-reload

chmod +x /usr/local/3proxy/conf/add3proxyuser.sh
proxy_pass="YOUR_PROXY_PASSWORD"
if [ -z $proxy_pass ]; then proxy_pass=$(pwgen 8 1); fi
/usr/local/3proxy/conf/add3proxyuser.sh admin ${proxy_pass}

# /usr/local/3proxy/conf/3proxy.cfg
cat << EOF1 > /usr/local/3proxy/conf/3proxy.cfg
nserver 8.8.8.8
config /conf/3proxy.cfg
monitor /conf/3proxy.cfg
monitor /conf/tunnels

log /logs/3proxy-%y%m%d.log D
rotate 60
counter /count/3proxy.3cf

users $/conf/passwd

include /conf/counters
include /conf/bandlimiters

auth strong
include /conf/tunnels
EOF1
###

if [ "${OSNAME}" = "debian" ]; then
cat << EOF2 > /etc/sudoers.d/proxy
proxy ALL=(root:root) NOPASSWD: /usr/bin/ss, /usr/bin/systemctl reload 3proxy, /usr/bin/systemctl restart 3proxy
EOF2
else
cat << EOF2 > /etc/sudoers.d/proxy
proxy ALL=(root:root) NOPASSWD: /usr/sbin/ss, /usr/bin/systemctl reload 3proxy, /usr/bin/systemctl restart 3proxy
EOF2
fi

systemctl enable --now 3proxy

git clone https://github.com/jitlogan/webui.git /usr/local/3proxy/webui
chown -R proxy:proxy /usr/local/3proxy/webui

cat << EOF3 > /etc/systemd/system/webui.service
[Unit]
Description=ruby sintra webui to 3proxy service
After=network.target nss-lookup.target

[Install]
WantedBy=multi-user.target

[Service]
User=proxy
User=proxy
Environment="APP_ENV=production"
WorkingDirectory=/usr/local/3proxy/webui
ExecStart=/usr/bin/ruby app.rb -o 0.0.0.0 -p8080
EOF3

pass="YOUR_UI_PASSWORD"
if [ -z $pass ]; then pass=$(pwgen 8 1); fi

echo -n "${pass}" | ruby -ryaml -ne 'puts({"username" => "admin", "password" => $_}.to_yaml)' > /usr/local/3proxy/webui/config.yml

systemctl enable --now webui

vm_export_variable output_pass "$pass" || :
vm_export_variable output_proxy_pass "$proxy_pass" || :