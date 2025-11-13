###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }


debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc qrencode
echo "Installed Dependencies"

cd /root

rlsmirror=${2:-https://github.com/minlearn/inst/releases/download/inital}
mkdir -p download
wget --no-check-certificate $rlsmirror/ovhauto.tar.gz -O download/tmp.tar.gz

mkdir -p app/ovhauto
tar -xzvf download/tmp.tar.gz -C app/ovhauto ovhauto

cat > /lib/systemd/system/ovhauto.service << 'EOL'
[Unit]
Description=this is ovhauto service,please change the token then daemon-reload it
After=network.target nss-lookup.target
Wants=network.target nss-lookup.target
Requires=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/root/app/ovhauto/ovhauto -config /root/app/ovhauto/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOL

# curl -X GET "https://eu.api.ovh.com/1.0/dedicated/server/datacenter/availabilities?planCode=26skleb01-v1" | jq
cat > /root/app/ovhauto/config.json << 'EOL'
app:
  key: "your_app_key"
  secret: "your_app_secret"
  consumer_key: "your_consumer_key"
  region: "ovh-eu"
  interval: 10  # 任务运行的时间间隔（秒）
  times: 2  # 要抢购的订单数
  
telegram:
  token: "your_telegram_bot_token"
  chat_id: "your_telegram_chat_id"
  
server:
  iam: "your_iam_identifier"
  zone: "IE"
  plan_name: "your_plan_name"
  required_plan_code: "26skleb01-v1"                             # 必填，curl得出，填错刷不出货
  required_datacenter: ""                                        # 可选，curl得出，填错刷不出货，不填不走具体datacenter
  required_disk: "softraid-2x450nvme"                            # 可选，curl得出，填错刷不出货，不填不走指定disk类型
  required_memory: ""                                            # 可选，curl得出，填错刷不出货
  options:                                                       # 必选，curl结果各项加-planccode，填错加不了购物车
    - "bandwidth-500-26skle"
    - "ram-32g-ecc-2400-26skleb01-v1"
    - "softraid-2x450nvme-26skleb01-v1"
  autopay: true                                                  # 可选，建议开启
  coupon: ""                                                     # 可选，没有码不填
EOL

cat > /root/tg.sh << 'EOL'
read -p "give a token:" token
read -p "give a chatid:" chatid
sed -e s#your_telegram_bot_token#${token}#g -e s#your_telegram_chat_id#${chatid}#g -i /root/app/ovhauto/config.json
systemctl restart ovhauto
EOL
chmod +x /root/tg.sh

cat > /root/keys.sh << 'EOL'
read -p "give a key:" key
read -p "give a secret:" secret
read -p "give a consumerkey:" consumerkey
sed -e s#your_app_key#${key}#g -e s#your_app_secret#${secret}#g -e s#your_consumer_key#${consumerkey}#g -i /root/app/ovhauto/config.json
systemctl restart ovhauto
EOL
chmod +x /root/keys.sh

cat > /root/plan.sh << 'EOL'
read -p "give a code:" code
sed -i s#24ska01#${code}#g /app/ovhauto/config.json
echo "please manually edit the options, which are neccsary for this plancode, then restart ovhauto"
systemctl restart ovhauto
EOL
chmod +x /root/plan.sh


systemctl enable -q --now ovhauto


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
