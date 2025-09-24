###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }

debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc lsof jq iptables
echo "Installed Dependencies"

get_latest_release() {
  curl -sL https://api.github.com/repos/$1/releases/latest | grep '"tag_name":' | cut -d'"' -f4
}
if command -v docker >/dev/null 2>&1; then
  echo "Docker 已安装"
else
  echo "Docker 正在安装"
  DOCKER_LATEST_VERSION=$(get_latest_release "moby/moby")
  echo "Installing Docker $DOCKER_LATEST_VERSION"
  DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
  mkdir -p $(dirname $DOCKER_CONFIG_PATH)
  echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
  silent sh <(curl -sSL https://get.docker.com)
  systemctl enable -q --now docker
  #offline docker setup
  #wget -q $rlsmirror/redroid/docker-24.0.7.gz -O download/docker-24.0.7.gz
  #tar --warning=no-timestamp -xzf download/docker-24.0.7.gz -C /usr/bin --strip-components=1
  #mkdir -p /etc/docker
  #echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
  #if [ ! -f /etc/systemd/system/docker.service ]; then
#cat >/etc/systemd/system/docker.service <<EOF
#[Unit]
#Description=Docker Application Container Engine
#After=network.target
#[Service]
#ExecStart=/usr/bin/dockerd
#ExecReload=/bin/kill -s HUP \$MAINPID
#LimitNOFILE=1048576
#LimitNPROC=1048576
#LimitCORE=infinity
#Delegate=yes
#KillMode=process
#[Install]
#WantedBy=multi-user.target
#EOF
  #fi
  #systemctl enable -q --now docker
fi


cd /root

rlsmirror=${2:-https://github.com/minlearn/inst/releases/download/inital}
mkdir -p download

echo "Docker data installing"
wget -q $rlsmirror/data.tar.gz -O download/data.tar.gz
tar --warning=no-timestamp -zxf download/data.tar.gz

#echo "Docker images installing"
#docker pull imagename:tag && docker save imagename:tag | xz -z -T0 - > imagename.tar.xz
#wget -q $rlsmirror/redroid/redroid12.tar.xz -O download/redroid12.tar.xz
#wget -q $rlsmirror/redroid/scrcpyweb.tar.xz -O download/scrcpyweb.tar.xz
#wget -q $rlsmirror/redroid/openresty.tar.xz -O download/openresty.tar.xz

if docker network ls --filter name=^mynet$ --format '{{.Name}}' | grep -qw mynet; then
  echo "docker 网络已存在"
else
  #docker network rm mynet
  docker network create --ipv6 --subnet "fd00:dead:beef:1::/64" mynet >/dev/null 2>&1
  echo "docker 网络不存在,已创建"
fi

canusefs=0
mkdir -p /dev/binderfs
if mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs 2>/dev/null; then
    canusefs=1
    echo "docker 设备已存在ng"

    if [ ! -f /etc/systemd/system/dev-binderfs.mount ]; then
    cat <<EOFF > /etc/systemd/system/dev-binderfs.mount
[Unit]
Description=Android binderfs mount

[Mount]
What=binder
Where=/dev/binderfs
Type=binder

[Install]
WantedBy=multi-user.target
EOFF
    systemctl enable -q dev-binderfs.mount
    fi

else {

all_exist=true
for i in $(seq 1 32); do
  if [ ! -e /dev/binder$i ]; then
    all_exist=false
  fi
done
if $all_exist; then
  echo "docker 设备已存在"
else
  if [ ! -f /etc/modprobe.d/binder.conf ]; then
    echo "options binder_linux devices=$(seq -s, -f 'binder%g' 1 32)" > /etc/modprobe.d/binder.conf
    echo 'binder_linux' > /etc/modules-load.d/binder_linux.conf
    echo 'KERNEL=="binder*", MODE="0666"' > /etc/udev/rules.d/70-binder.rules
  fi
  #rm -f /dev/binder*
  #rmmod binder_linux
  modprobe binder_linux devices=$(seq -s, -f 'binder%g' 1 32)
  chmod 666 /dev/binder*
  echo "docker 设备不全，已补全"
fi

}; fi

<<'BLOCK'
for i in ashmem:61 binder:60 hwbinder:59 vndbinder:58;do
  if [ ! -e /dev/${i%%:*} ]; then
    mknod /dev/${i%%:*} c 10 ${i##*:}
    chmod 777 /dev/${i%%:*}
    #chown root:${i%%:*} /dev/${i%%:*}
  fi
done
BLOCK

# we add this extra anyway
modprobe mac80211_hwsim
if [ ! -f /etc/modules-load.d/mac80211_hwsim.conf ]; then
  echo 'mac80211_hwsim' > /etc/modules-load.d/mac80211_hwsim.conf
fi

cat > add.sh << 'EOF'
cd /root

if ! docker ps -q -f name=^scrcpy$ | grep -q .; then
  echo -e "\n create scrcpy"
  #if [ ! "$(docker images | grep scrcpy-web)" ] && [ -f download/scrcpyweb.tar.xz ]; then xz -dc download/scrcpyweb.tar.xz | docker load; fi
  docker run -itd \
    --name scrcpy \
    --network=mynet \
    --restart=always \
    --privileged \
    -v ./data/scrcpy-web/data:/data \
    -v ./data/scrcpy-web/apk:/apk \
    emptysuns/scrcpy-web:v0.1
fi

if ! docker ps -q -f name=^nginx$ | grep -q .; then
echo -e "\n create nginx"
#if [ ! "$(docker images | grep openresty)" ] && [ -f download/openresty.tar.xz ]; then xz -dc download/openresty.tar.xz | docker load; fi
docker run -itd \
    --name nginx \
    --network=mynet \
    --restart=always \
    -v ./data/nginx/conf.d:/etc/nginx/conf.d \
    -p 8055:80 \
    openresty/openresty:1.21.4.1-0-alpine
fi

    canusefs=0
if mountpoint -q /dev/binderfs; then
    canusefs=1
    echo "ng found"
fi

leastfilenum=$(comm --nocheck-order -23 <(seq 1 100 | sort -n) <(find data/redroid -regex 'data/redroid/data[0-9]+$' | grep -Eo '[0-9]+$' | sort -n) | head -n1)
free=$(comm --nocheck-order -23 <(seq 1 32 | sort -n) <(for i in $(docker ps -a --filter ancestor=$( [ -z "$1" ] && echo "redroid/redroid:12.0.0-latest" || echo "$1" ) --format '{{.Names}}'); do docker inspect "$i" | jq -r '.[0].Mounts[] | select(.Source|startswith("/dev/binder")) | .Source'; done | grep -o '[0-9]\+' | sort -n -u) | awk '{print "/dev/binder"$1}')

if ! docker ps -q -f name=^redroid"$leastfilenum"$ | grep -q .; then

if [ "$canusefs" == "0" ]; then
  found1=""
  found2=""
  found3=""
  for i in $free; do
    if [ -e $i ] && ! lsof $i >/dev/null 2>&1; then
      if [ -z "$found1" ]; then
        found1="$i"
      elif [ -z "$found2" ]; then
        found2="$i"
      elif [ -z "$found3" ]; then
        found3="$i"
        break
      fi
    fi
  done

  if [ -z "$found1" ] || [ -z "$found2" ] || [ -z "$found3" ]; then
    echo "error: not enough /dev/binder"
    exit 1
  fi
  echo "found: $found1,$found2,$found3"
fi

  echo -e "\n create redroid$leastfilenum"
  #if [ ! "$(docker images | grep redroid)" ] && [ -f download/redroid12.tar.xz ]; then xz -dc download/redroid12.tar.xz | docker load; fi
  docker run -itd \
    --name=redroid"$leastfilenum" \
    --network=mynet \
    --restart=always \
    --privileged \
    --memory-swappiness=0 \
    $( [ "$canusefs" == "0" ] && echo "-v "$found1":/dev/binder -v "$found2":/dev/hwbinder -v "$found3":/dev/vndbinder" ) \
    -v ./data/redroid/data"$leastfilenum":/data \
    $( [ -z "$1" ] && echo "redroid/redroid:12.0.0-latest" || echo "$1" ) \
    androidboot.hardware=mt6891 ro.secure=0 ro.boot.hwc=GLOBAL ro.ril.oem.imei=861503068361145 ro.ril.oem.imei1=861503068361145 ro.ril.oem.imei2=861503068361148 ro.ril.miui.imei0=861503068361148 ro.product.manufacturer=Xiaomi ro.build.product=chopin redroid.width=720 redroid.height=1280 redroid.gpu.mode=guest
fi

sleep 5
echo -e "\n scrcpy adb connect redroid$leastfilenum"
timeout 10s docker exec scrcpy adb connect redroid"$leastfilenum":5555
j=0
while (( j < 20 )); do 
  if ! timeout 10s docker exec scrcpy adb get-state 1>/dev/null 2>&1; then
    echo "Host not ready(modules lost/permisson lost/binder engaged)? try reconnect"
    timeout 10s docker exec scrcpy adb devices | grep -q "^redroid${leastfilenum}:5555" && echo "connected" && break
  else
    if ! timeout 10s docker exec scrcpy adb devices 1>/dev/null 2>&1| grep -q "^redroid${leastfilenum}:5555"; then
      echo "redroid not ready? try reconnect"
      timeout 10s docker exec scrcpy adb devices | grep -q "^redroid${leastfilenum}:5555" && echo "connected" && break
    fi
  fi
  sleep 5
  timeout 10s docker exec scrcpy adb connect redroid"$leastfilenum":5555
  ((j++))
done

sleep 5
echo -e "\n install APK"
for file in `ls ./data/scrcpy-web/apk`
do
    if [[ -f "./data/scrcpy-web/apk/"$file ]]; then
      echo "installing $file"
      docker exec scrcpy adb -s redroid"$leastfilenum" install /apk/$file
    fi
done
EOF
chmod +x ./add.sh

cat > reconnect.sh << 'EOF'
#without -a,only reconnect active
names=$(docker ps --filter ancestor=$( [ -z "$1" ] && echo "redroid/redroid:12.0.0-latest" || echo "$1" ) --format '{{.Names}}')

for i in $names; do
  echo -e "\n scrcpy adb connect $i"
  docker exec scrcpy adb connect "$i":5555
  j=0
  while (( j < 20 )); do 
    if ! docker exec scrcpy adb get-state 1>/dev/null 2>&1; then
      echo "Host not ready(modules lost/permisson lost/binder engaged)? try reconnect"
      docker exec scrcpy adb devices | grep -q "^${i}:5555" && echo "connected" && break
    else
      if ! docker exec scrcpy adb devices 1>/dev/null 2>&1| grep -q "^${i}:5555"; then
        echo "redroid not ready? try reconnect"
        docker exec scrcpy adb devices | grep -q "^${i}:5555" && echo "connected" && break
      fi
    fi
    sleep 5
    docker exec scrcpy adb connect "$i":5555
    ((j++))
  done
done
EOF
chmod +x ./reconnect.sh

cat > clean.sh << 'EOF'
read -r -p "Are you sure to del all? <y/N> " prompt </dev/tty
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  names=$(docker ps -a --filter ancestor=$( [ -z "$1" ] && echo "redroid/redroid:12.0.0-latest" || echo "$1" ) --format '{{.Names}}');[ -n "$names" ] && docker stop $names && docker rm $names
  rm -rf data/redroid/data*

  docker restart scrcpy
  docker restart nginx
fi
EOF
chmod +x ./clean.sh


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
