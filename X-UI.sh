#!/bin/bash
## OS: "centos9","ubuntu2004","ubuntu2204","ubuntu2404","debian11","debian12"

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
RNAME=x-ui
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

if [ -f /etc/redhat-release ]; then
  OSNAME=centos
  OSREL=$(printf '%.0f' $(rpm -qf --qf '%{version}' /etc/redhat-release))
else
  OSNAME=debian
fi

if [ "${OSNAME}" = "debian" ]; then
  apt-mark hold qemu-guest-agent
  apt update
  apt install -y curl sqlite3 pwgen
else
  if [ "${OSREL}" = 7 ]; then
    yum -x qemu-guest-agent update -y
    yum install -y epel-release
    yum install -y curl sqlite3 pwgen
    yum remove firewalld -y
  fi

  if [ "${OSREL}" = 8 ]; then
    dnf -x qemu-guest-agent update -y
    dnf install -y epel-release
    dnf install -y curl sqlite pwgen
    dnf remove firewalld -y
    dnf install -y dnf-plugin-versionlock
    dnf versionlock qemu-guest-agent    
  fi

  if [ "${OSREL}" = 9 ]; then
    dnf config-manager --set-enabled crb
    dnf -x qemu-guest-agent update -y
    dnf install -y epel-release epel-next-release
    dnf install -y curl sqlite pwgen wget
    dnf remove firewalld -y
    dnf install -y dnf-plugin-versionlock
    dnf versionlock qemu-guest-agent
  fi
fi

#curl -fsSL https://raw.githubusercontent.com/NidukaAkalanka/x-ui-english/master/install.sh -o install.sh
curl -fsSL https://raw.githubusercontent.com/alireza0/x-ui/master/install.sh -o install.sh
chmod +x install.sh
username=$(pwgen 8 1)
echo $username|/root/install.sh

username=""
password=""
port=""

/usr/bin/x-ui stop

if [ -n "" ]; then
    # sqlite3 /etc/x-ui-english/x-ui-english.db "update users set username='$username' where id=1"
    sqlite3 /etc/x-ui/x-ui.db "update users set username='$username' where id=1"
fi

if [ -z $password ]; then
    password=$(sqlite3 /etc/x-ui/x-ui.db "select * from users"|awk -F '|' '{print $3}')
else
    sqlite3 /etc/x-ui/x-ui.db "update users set password='$password' where id=1"
fi

if [ -z $port ]; then
    port=$(shuf -i 1024-65535 | head -1)
    #port=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='webPort'")
    sqlite3 /etc/x-ui/x-ui.db "insert into settings (key, value) values ('webPort', '$port')"
else
    # sqlite3 /etc/x-ui/x-ui.db "update settings set value = '$port' where key = 'webPort'"
    # sqlite3 /etc/x-ui/x-ui.db "insert into settings (key, value) values ('webPort', '$port')"
    # port=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='webPort'")
    port=$port
    sqlite3 /etc/x-ui/x-ui.db "update settings set value='$port' where key='webPort'"
fi

/usr/bin/x-ui start
########## unlock the package qemu-guest-agent################
dnf versionlock delete qemu-guest-agent
##############################################################
username=$(sqlite3 /etc/x-ui/x-ui.db "select * from users"|awk -F '|' '{print $2}')
password=$(sqlite3 /etc/x-ui/x-ui.db "select * from users"|awk -F '|' '{print $3}')
port=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where ID='1';")
#port=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='webPort'")
webbasepath=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='webBasePath'")

vm_export_variable output_username "$username" || :
vm_export_variable output_password "$password" || :
vm_export_variable output_port "$port" || :
vm_export_variable output_webbasepath "$webbasepath" || :