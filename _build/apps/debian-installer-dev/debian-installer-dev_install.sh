###############

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }


debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y \
  curl \
  sudo \
  mc \
  gpg
echo "Installed Dependencies"



silent apt-get install -y git
silent apt-get install -y build-essential autoconf libtool pkg-config
silent apt-get install -y libdebconfclient0-dev libdebian-installer4-dev libiw-dev

echo "Installing"

cd /root

# rootskel first
# 1.133
silent git clone https://salsa.debian.org/installer-team/rootskel.git debian-install
silent git -C debian-install checkout 1.133

# 0.260
silent git -C debian-install clone https://salsa.debian.org/installer-team/cdebconf.git
silent git -C debian-install/cdebconf checkout 0.260
# 1.140
silent git -C debian-install clone https://salsa.debian.org/installer-team/debian-installer-utils.git
silent git -C debian-install/debian-installer-utils checkout 1.140
# 0.121
silent git -C debian-install clone https://salsa.debian.org/installer-team/libdebian-installer.git
silent git -C debian-install/libdebian-installer checkout 0.121
# 1.62
silent git -C debian-install clone https://salsa.debian.org/installer-team/main-menu.git
silent git -C debian-install/main-menu checkout 1.62
# 1.109
silent git -C debian-install clone https://salsa.debian.org/installer-team/preseed.git
silent git -C debian-install/preseed checkout 1.109
# 1.20
silent git -C debian-install clone https://salsa.debian.org/installer-team/udpkg.git
silent git -C debian-install/udpkg checkout 1.20

echo "Installed"

tar cpzf debian-installer.tar.gz debian-install

cd /root/debian-install
for i in cdebconf debian-installer-utils main-menu preseed udpkg; do
  (cd $i && apt-get build-dep -y . && dpkg-buildpackage -us -uc -b)
done

echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
