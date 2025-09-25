###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }

debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc
echo "Installed Dependencies"

cd /root

rlsmirror=${2:-https://github.com/minlearn/inst/releases/download/inital}
mkdir -p download
wget --no-check-certificate $rlsmirror/xmrig-6.22.2-linux-static-x64.tar.gz -O download/tmp.tar.gz

mkdir -p app/xmrig
tar -xzvf download/tmp.tar.gz -C app/xmrig xmrig-6.22.2 --strip-components=1

cat > /lib/systemd/system/xmrig.service << 'EOL'
[Unit]
Description=this is xmrig service,please bash /root/init.sh to update
After=network.target nss-lookup.target
Wants=network.target nss-lookup.target
Requires=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=/bin/bash -c "PATH=/usr/local/bin:$PATH exec /root/app/xmrig/xmrig -a rx -o stratum+ssl://rx.unmineable.com:443 -u SHIB:0x0000000000000000000000000000000000000.amd-$$[RANDOM%%65535] -p x -t $$(nproc)"
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOL

cat > /root/init.sh << 'EOL'
read -p "give a coin(SHIB/DOGE):" coin
sed -i "s#SHIB#${coin}#g" /lib/systemd/system/xmrig.service
read -p "give a address(SHIB/DOGE):" addr
sed -i "s#0x0000000000000000000000000000000000000#${addr}#g" /lib/systemd/system/xmrig.service
systemctl daemon-reload
systemctl restart xmrig
EOL
chmod +x /root/init.sh

systemctl enable -q --now xmrig


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
