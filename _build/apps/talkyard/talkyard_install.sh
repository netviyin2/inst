###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }


debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc
echo "Installed Dependencies"

silent apt-get install -y openjdk-11-jdk postgresql-client git unzip cpp

curl -sL https://deb.nodesource.com/setup_16.x | bash -
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
silent apt-get update -y
silent apt-get install nodejs yarn -y
echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" | tee /etc/apt/sources.list.d/sbt.list
echo "deb https://repo.scala-sbt.org/scalasbt/debian /" | tee /etc/apt/sources.list.d/sbt_old.list
curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | tee /etc/apt/trusted.gpg.d/sbt.asc
silent apt-get update
silent apt-get install sbt

cd /root
git clone https://github.com/debiki/talkyard.git
cd talkyard
git checkout 9ef9b55d16301fa67087993c83b2a954aae323f4

cat > /root/compile.sh << 'EOL'
cd /root/talkyard

if [ ! -f Globals.scala.bak ]; then
  cp appsv/server/debiki/Globals.scala Globals.scala.bak
  cat << 'PATCH' | patch appsv/server/debiki/Globals.scala && echo "补丁已应用" || echo "应用失败"
48a49
> import scala.util.{Try, Success, Failure}
1338a1340,1350
>     // 先检查 DNS 是否可以解析，如果不行就跳过搜索初始化
>     val canResolveSearchHost: Boolean = Try {
>       jn.InetAddress.getByName(elasticSearchHost)
>       true
>     } match {
>       case Success(_) => true
>       case Failure(ex) =>
>         logger.warn(s"✗ Cannot resolve search host '$elasticSearchHost', search will be DISABLED [TyWSRCHDNS]")
>         false
>     }
> 
1340,1343c1352,1360
<       new es.transport.client.PreBuiltTransportClient(es.common.settings.Settings.EMPTY)
<         .addTransportAddress(
<           new es.common.transport.TransportAddress(
<             jn.InetAddress.getByName(elasticSearchHost), 9300))
---
>       if (canResolveSearchHost) {
>         new es.transport.client.PreBuiltTransportClient(es.common.settings.Settings.EMPTY)
>           .addTransportAddress(
>             new es.common.transport.TransportAddress(
>               jn.InetAddress.getByName(elasticSearchHost), 9300))
>       } else {
>         // DNS 解析失败，创建一个 dummy client（不会被使用）
>         new es.transport.client.PreBuiltTransportClient(es.common.settings.Settings.EMPTY)
>       }
1379a1397,1400
>       else if (!canResolveSearchHost) {
>         logger.info(s"Skipping search indexer (search host unresolvable) [TyMNOINDEXER]")
>         None
>       }  
PATCH
fi
find appsv/server -type f -name '*.scala' -print0 | xargs -0 sed -i 's#opt/talkyard#root/talkyard/build#g'
git submodule update --init --recursive
export PLAY_HEAP_MEMORY_MB=1024
sbt compile
sbt stage
yarn
# https://github.com/debiki/talkyard/blob/main/makefile
npx gulp compileServerTypescriptConcatJavascript

# https://github.com/debiki/talkyard/blob/main/s/impl/build-prod-app-image.sh
rm -rf build
mkdir -p build
cp -a images/app/assets build/
mv target/universal/stage build/app
cp version.txt build/app/version.txt
rm -rf target

# https://github.com/debiki/talkyard-prod-one/raw/refs/heads/main/conf/play-framework.conf
echo -en "\ntalkyard.postgresql.host=\"rdb\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.port=\"5432\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.database=\"talkyard\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.user=\"talkyard\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.password=\"talkyard\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.redis.host=\"cache\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl

echo -en "\ntalkyard.hostname=\"localhost\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.secure=false" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
echo -en "\nplay.http.secret.key=\"change_this\"" >> /root/talkyard/build/app/conf/app-prod-override.conf.tpl
EOL

cat > /root/start.sh << 'EOL'
#!/bin/bash

#ihttps://github.com/debiki/talkyard/blob/main/images/rdb/docker-entrypoint-initdb.d/init.sh
if [ ! -f /root/inited ]; then
  read -p "give a dbip(127.0.0.1,10.10.10.x,etc..):" ip
  read -p "give a dbpassword:" pw
  read -p "give a redis server ip:" rip

  cp /root/talkyard/build/app/conf/app-prod-override.conf.tpl /root/talkyard/build/app/conf/app-prod-override.conf
  sed -i "/talkyard.postgresql.host=\"/c\talkyard.postgresql.host=\"$ip\"" /root/talkyard/build/app/conf/app-prod-override.conf
  sed -i "/talkyard.redis.host=\"/c\talkyard.redis.host=\"$rip\"" /root/talkyard/build/app/conf/app-prod-override.conf
  sed -i "/talkyard.hostname=\"/c\talkyard.hostname=\"$ip\"" /root/talkyard/build/app/conf/app-prod-override.conf
  sed -i "/play.http.secret.key=\"/c\play.http.secret.key=\"key-1111111111111111111111111111111111111111111\"" /root/talkyard/build/app/conf/app-prod-override.conf

  PGPASSWORD="$pw" psql -h $ip -p 5432 -U postgres << EOF
    DROP DATABASE talkyard;
    CREATE ROLE talkyard WITH LOGIN PASSWORD 'talkyard';
    CREATE DATABASE talkyard OWNER talkyard;
    GRANT ALL PRIVILEGES ON DATABASE talkyard TO talkyard;
EOF
  touch /root/inited
fi

cd /root/talkyard/build

# https://github.com/debiki/talkyard/blob/main/images/app/Dockerfile.prod
rm -rf /root/talkyard/build/RUNNING_PID
export PLAY_HEAP_MEMORY_MB=1024

/root/talkyard/build/app/bin/talkyard-server \
  -J-Xms${PLAY_HEAP_MEMORY_MB}m \
  -J-Xmx${PLAY_HEAP_MEMORY_MB}m \
  -Dhttp.port=9000 \
  -Dlogback.configurationFile=/root/talkyard/build/app/conf/logback-prod.xml \
  -Dconfig.file=/root/talkyard/build/app/conf/app-prod.conf
EOL

echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
