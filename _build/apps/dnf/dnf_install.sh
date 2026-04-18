###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }


debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc gnupg netcat
echo "Installed Dependencies"

dpkg --add-architecture i386
silent apt-get update -y
silent apt-get -y install libc6:i386 libstdc++6:i386 zlib1g:i386

if apt list --installed 2>/dev/null | grep -q 'mysql-community-client/.*5\.6\.'; then
    echo "mysql-community-client 5.6 已安装，不装 default-mysql-client,如果继续安装，5.6可能会被mask。"
else
    silent apt-get -y install default-mysql-client
fi

cd /root

rlsmirror=${2:-https://github.com/minlearn/inst/releases/download/inital}
mkdir -p download
wget -q --no-check-certificate $rlsmirror/dnfserver.tar.xz -O download/server.tar.xz

DNFS_DIR=/root/app/dnf
SERVER_GROUP_NAME=cain
SERVER_GROUP_DB=cain
SERVER_GROUP=3
PUBLIC_IP=$(curl -s https://ipinfo.io/ip) || echo "PUBLIC_IP"

echo "Installing dnf..."
mkdir -p ${DNFS_DIR}
tar -xJf download/server.tar.xz -C ${DNFS_DIR} --strip-components=1
cp ${DNFS_DIR}/libhook.so /usr/lib/i386-linux-gnu/
cp ${DNFS_DIR}/libhook.so /lib/i386-linux-gnu/
cp ${DNFS_DIR}/libnxencryption.so /usr/lib/i386-linux-gnu/
cp ${DNFS_DIR}/libnxencryption.so /lib/i386-linux-gnu/


for i in \
  "stun::stun:start_stun.sh"\
  "monitor:dnf_stun:monitor:start_monitor.sh"\
  "manager:dnf_monitor:manager:start_manager.sh"\
  "relay:dnf_manager:relay:start_relay.sh"\
  "bridge:dnf_relay:bridge:start_bridge.sh"\
  "channel:dnf_bridge:channel:start_channel.sh"\
  "dbmw_guild:dnf_channel:dbmw_guild:start_dbmw_guild.sh"\
  "dbmw_mnt:dnf_dbmw_guild:dbmw_mnt:start_dbmw_mnt.sh"\
  "dbmw_stat:dnf_dbmw_mnt:dbmw_stat:start_dbmw_stat.sh"\
  "auction:dnf_dbmw_stat:auction:start_auction.sh"\
  "point:dnf_auction:point:start_point.sh"\
  "guild:dnf_point:guild:start_guild.sh"\
  "statics:dnf_guild:statics:start_statics.sh"\
  "coserver:dnf_statics:coserver:start_coserver.sh"\
  "community:dnf_coserver:community:start_community.sh"\
  "gunnersvr:dnf_community:secsvr/gunnersvr:start_gunnersvr.sh"\
  "zergsvr1:dnf_gunnersvr:secsvr/zergsvr:start_zergsvr_secagent.sh"\
  "zergsvr2:dnf_zergsvr1:secsvr/zergsvr:start_zergsvr.sh"\
  "game:game:start_game.sh"\
;do
  name=$(echo $i | cut -d: -f1)
  deps=$(echo $i | cut -d: -f2)
  dir=$(echo $i | cut -d: -f3)
  exec=$(echo $i | cut -d: -f4)

  echo "Creating systemd service for $name"
  cat <<EOF >/lib/systemd/system/dnf_$name.service
[Unit]
Description=$name
After=syslog.target network.target
After=$deps

[Service]
Environment=dm=_r
RestartSec=2s
Type=simple
WorkingDirectory=${DNFS_DIR}/build/$dir
ExecStart=bash $exec
Restart=always

[Install]
WantedBy=multi-user.target
EOF
done


cat <<EOF >/root/init.sh
#!/bin/bash

if [ -f /root/inited ]; then echo "already inited, del /root/inited to re init"; fi
if [ ! -f /root/inited ]; then
read -p "give a dbip(127.0.0.1,10.10.10.x,publicip,etc..):" ip
read -p "give a dbpassword:" pw
HOSTNAME=\$ip
PORT="3306"
USERNAME="root"
PASSWORD=\${pw/\//\\\/}

while true; do
  read -p "give a dbpassword for game (exactly 8 chars): " gpw
  if [ \${#gpw} -eq 8 ]; then
    GAMEUSERPASSWORD=\${gpw/\//\\\/}
    mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} -e "GRANT ALL PRIVILEGES ON *.* TO 'game'@'localhost' IDENTIFIED BY '\$GAMEUSERPASSWORD' WITH GRANT OPTION;FLUSH PRIVILEGES;"
    break
  else
    echo "密码必须8位，请重新输入！"
  fi
done

# Wait for Mysql to become available.
until nc -z -v -w30 \${HOSTNAME} 3306; do
  echo "Database @\${HOSTNAME} not yet available. Sleeping..."
  sleep 10
done

mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} -e "SELECT VERSION();" | grep -q "5.6"
if [ \$? -ne 0 ]; then
  echo "MySQL 版本不是5.6或验证失败，脚本退出"
  exit 1
fi

# 循环初始化主数据库
MAIN_DB_LIST=("d_taiwan" "d_taiwan_secu" "d_technical_report")
for db_name in "\${MAIN_DB_LIST[@]}"
do
    echo "prepare init \$db_name....."
    echo "main db: prepare to init remote mysql service dnf data."
    mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
    CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
    use \$db_name;
    source ${DNFS_DIR}/database/\$db_name.sql;
    flush PRIVILEGES;
EOFEOF
done

# 准备加密的GAME用户密码
DEC_GAME_PWD=\$(echo -n "\$GAMEUSERPASSWORD" | ${DNFS_DIR}/TeaEncrypt) || echo "DEC_GAME_PWD"
# 重置当前大区的主数据库d_taiwan.db_connect表配置
mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
use d_taiwan;
update db_connect set db_ip="127.0.0.1", db_port="3307", db_name="d_taiwan", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type = 1;
update db_connect set db_ip="127.0.0.1", db_port="3307", db_name="d_taiwan_secu", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type = 10;
update db_connect set db_ip="127.0.0.1", db_port="3307", db_name="d_technical_report", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type = 15;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="d_guild", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type = 8;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_${SERVER_GROUP_DB}", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=2;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_${SERVER_GROUP_DB}_2nd", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=3;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_${SERVER_GROUP_DB}_log", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=4;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_${SERVER_GROUP_DB}_web", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=5;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_login", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=6;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_prod", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=7;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_game_event", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=9;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_login_play", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=11;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_${SERVER_GROUP_DB}_auction_gold", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=12;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_se_event", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=13;
update db_connect set db_ip="127.0.0.1", db_port="3306", db_name="taiwan_billing", db_passwd="\$DEC_GAME_PWD" where db_server_group=$SERVER_GROUP and db_type=14;
EOFEOF
# 测试并查询数据库连接设置
mysql -h\${HOSTNAME} -P\${PORT} -ugame -p\${GAMEUSERPASSWORD} <<EOFEOF
select db_name, db_ip, db_port, db_passwd from d_taiwan.db_connect where db_server_group=$SERVER_GROUP;
EOFEOF
echo "main_db: init server group-$SERVER_GROUP($SERVER_GROUP_DB) done."

# 循环初始化大区数据库
SG_DB_LIST=("d_channel_${SERVER_GROUP_DB}" "d_guild" "taiwan_${SERVER_GROUP_DB}" "taiwan_${SERVER_GROUP_DB}_2nd" "taiwan_${SERVER_GROUP_DB}_log" "taiwan_${SERVER_GROUP_DB}_web" "taiwan_${SERVER_GROUP_DB}_auction_gold" "taiwan_${SERVER_GROUP_DB}_auction_cera" "taiwan_login" "taiwan_prod" "taiwan_game_event" "taiwan_se_event" "taiwan_login_play" "taiwan_billing")
# 希洛克数据库特殊，要优先作处理，因为其他组件会提前初始化这个数据库导致其跳过首次初始化
for db_name in "\${SG_DB_LIST[@]}"
do
    echo "prepare init \$db_name....."
    if [ "\$db_name" == "taiwan_siroco" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA IF NOT EXISTS \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain.sql;
      flush PRIVILEGES;
EOFEOF
    fi
done
# 其它普通处理
for db_name in "\${SG_DB_LIST[@]}"
do
    echo "prepare init \$db_name....."
    if [ "\$db_name" == "d_channel_$SERVER_GROUP_DB" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/d_channel.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_$SERVER_GROUP_DB" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_${SERVER_GROUP_DB}_2nd" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain_2nd.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_${SERVER_GROUP_DB}_log" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain_log.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_${SERVER_GROUP_DB}_web" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain_web.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_${SERVER_GROUP_DB}_auction_gold" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain_auction_gold.sql;
      flush PRIVILEGES;
EOFEOF
      continue
    fi
    if [ "$db_name" == "taiwan_${SERVER_GROUP_DB}_auction_cera" ]; then
      mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
      CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
      use \$db_name;
      source ${DNFS_DIR}/database/taiwan_cain_auction_cera.sql;
      flush PRIVILEGES;
EOFEOF
      continue 
    fi

    # 兜底
    mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
    CREATE SCHEMA \$db_name DEFAULT CHARACTER SET utf8 ;
    use \$db_name;
    source ${DNFS_DIR}/database/taiwan_cain_auction_cera.sql;
    flush PRIVILEGES;
EOFEOF
done
# 测试并查询数据库连接设置
echo "server group db: show db_connect config, server_group is $SERVER_GROUP"
mysql -h\${HOSTNAME} -P\${PORT} -u\${USERNAME} -p\${pw} <<EOFEOF
select gc_type, gc_ip, gc_channel from taiwan_$SERVER_GROUP_DB.game_channel where gc_type=$SERVER_GROUP;
EOFEOF

# Process environment variables in the configuration files.
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#SERVER_GROUP_NAME#${SERVER_GROUP_NAME}#g" "R"
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#SERVER_GROUP_DB#${SERVER_GROUP_DB}#g" "R"
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#SERVER_GROUP#${SERVER_GROUP}#g" "R"
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#PUBLIC_IP#${PUBLIC_IP}#g" "R"
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#DEC_GAME_PWD#\$DEC_GAME_PWD#g" "R"
find ${DNFS_DIR}/build -type f -name "*.cfg" -print0 | xargs -0 -I "R" sed -i "s#GAME_PASSWORD#\$DEC_GAME_PWD#g" "R"
echo "配置文件修改成功"

systemctl restart dnf_*
touch /root/inited
fi
EOF
chmod +x /root/init.sh

for svc in /lib/systemd/system/dnf_*.service; do systemctl enable -q --now $(basename "$svc"); done

echo "dnf installation completed successfully!"
echo "You can access it at: tcp "


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
