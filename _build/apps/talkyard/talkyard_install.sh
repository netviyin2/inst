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

cat > /root/compile.sh << 'EOL'
cd /root
git clone https://github.com/debiki/talkyard.git
git checkout 9ef9b55d16301fa67087993c83b2a954aae323f4
cd talkyard
git submodule update --init --recursive
export PLAY_HEAP_MEMORY_MB=1024
sbt compile
sbt dist
yarn
# https://github.com/debiki/talkyard/blob/main/makefile
npx gulp compileServerTypescriptConcatJavascript

# https://github.com/debiki/talkyard/blob/main/s/impl/build-prod-app-image.sh
rm -rf /opt/talkyard
mkdir -p /opt/talkyard
cp -a images/app/assets /opt/talkyard/
version="`cat version.txt | sed s/WIP/SNAPSHOT/`"
if [[ ! -f target/universal/talkyard-server-$version.zip ]]; then
  echo "Error: output File target/universal/talkyard-server-$version.zip not found."
  exit 1
fi
unzip -o -q target/universal/talkyard-server-$version.zip -d /opt/talkyard
cp version.txt /opt/talkyard/talkyard-server-$version/version.txt
mv /opt/talkyard/talkyard-server-$version /opt/talkyard/app
rm -rf /root/talkyard

# https://github.com/debiki/talkyard-prod-one/raw/refs/heads/main/conf/play-framework.conf
echo -en "\ntalkyard.postgresql.host=\"rdb\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.port=\"5432\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.database=\"talkyard\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.user=\"talkyard\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.postgresql.password=\"talkyard\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.redis.host=\"cache\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl

echo -en "\ntalkyard.hostname=\"localhost\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\ntalkyard.secure=false" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
echo -en "\nplay.http.secret.key=\"change_this\"" >> /opt/talkyard/app/conf/app-prod-override.conf.tpl
EOL

cat > /root/start.sh << 'EOL'
#!/bin/bash

#ihttps://github.com/debiki/talkyard/blob/main/images/rdb/docker-entrypoint-initdb.d/init.sh
if [ ! -f /root/inited ]; then
  read -p "give a dbip(127.0.0.1,10.10.10.x,etc..):" ip
  read -p "give a dbpassword:" pw
  read -p "give a redis server ip:" rip

  cp /opt/talkyard/app/conf/app-prod-override.conf.tpl /opt/talkyard/app/conf/app-prod-override.conf
  sed -i "/talkyard.postgresql.host=\"/c\talkyard.postgresql.host=\"$ip\"" /opt/talkyard/app/conf/app-prod-override.conf
  sed -i "/talkyard.redis.host=\"/c\talkyard.redis.host=\"$rip\"" /opt/talkyard/app/conf/app-prod-override.conf
  sed -i "/talkyard.hostname=\"/c\talkyard.hostname=\"$ip\"" /opt/talkyard/app/conf/app-prod-override.conf
  sed -i "/play.http.secret.key=\"/c\play.http.secret.key=\"key-1111111111111111111111111111111111111111111\"" /opt/talkyard/app/conf/app-prod-override.conf

  PGPASSWORD="$pw" psql -h $ip -p 5432 -U postgres << EOF
    DROP DATABASE talkyard;
    CREATE ROLE talkyard WITH LOGIN PASSWORD 'talkyard';
    CREATE DATABASE talkyard OWNER talkyard;
    GRANT ALL PRIVILEGES ON DATABASE talkyard TO talkyard;
EOF
  touch /root/inited
fi

cd /opt/talkyard

# https://github.com/debiki/talkyard/blob/main/images/app/Dockerfile.prod
rm -rf /opt/talkyard/RUNNING_PID
PLAY_HEAP_MEMORY_MB=1024 /opt/talkyard/app/bin/talkyard-server \
  -J-Xms${PLAY_HEAP_MEMORY_MB}m \
  -J-Xmx${PLAY_HEAP_MEMORY_MB}m \
  -Dhttp.port=9000 \
  -Dlogback.configurationFile=/opt/talkyard/app/conf/logback-prod.xml \
  -Dconfig.file=/opt/talkyard/app/conf/app-prod.conf
EOL

echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
