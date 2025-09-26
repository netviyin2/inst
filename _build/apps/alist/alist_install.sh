###############################

silent() { "$@" >/dev/null 2>&1 || { echo "Error running: $*"; echo "sth error"; exit 1; }; }


debmirror=${1:-http://deb.debian.org/debian}
echo -e "deb ${debmirror} bullseye main\ndeb ${debmirror} bullseye-updates main\ndeb ${debmirror}-security bullseye-security main" > /etc/apt/sources.list

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc
echo "Installed Dependencies"

RELEASE=$(wget -q https://github.com/AlistGo/alist/releases/latest -O - | grep "title>Release" | cut -d " " -f 4 | sed 's/^v//')
arch=$([[ "$(arch)" == "aarch64" ]] && echo arm64||echo amd64)
wget -q https://github.com/AlistGo/alist/releases/download/v$RELEASE/alist-linux-musl-$arch.tar.gz
tar zxf alist-linux-musl-$arch.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/alist

echo "Installing alist"

echo "Creating Service"
cat <<EOF >/etc/systemd/system/alist.service
[Unit]
Description=Alist file list service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/alist server
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now alist
echo "Created Service"


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

###############################
