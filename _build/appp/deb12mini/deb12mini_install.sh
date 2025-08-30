###############

silent() { "$@" >/dev/null 2>&1; }

echo "Installing Dependencies"
silent apt-get update -y
silent apt-get install -y curl sudo mc
echo "Installed Dependencies"

silent apt-get install -y debootstrap debian-archive-keyring jq dpkg-dev gnupg apt-transport-https ca-certificates curl gpg

cat > /usr/share/debootstrap/scripts/bookworm <<-'EOF'

mirror_style release
download_style apt
finddebs_style from-indices
variants - container fakechroot
keyring /usr/share/keyrings/debian-archive-keyring.gpg

if doing_variant fakechroot; then
	test "$FAKECHROOT" = "true" || error 1 FAKECHROOTREQ "This variant requires fakechroot environment to be started"
fi

case $ARCH in
	alpha|ia64) LIBC="libc6.1" ;;
	kfreebsd-*) LIBC="libc0.1" ;;
	hurd-*)     LIBC="libc0.3" ;;
	*)          LIBC="libc6" ;;
esac

work_out_debs () {
	required="adduser base-files base-passwd bash bsdutils coreutils dash debian-archive-keyring diffutils dpkg findutils grep gzip hostname init-system-helpers libc-bin login lsb-base mawk ncurses-base passwd sed sysv-rc tar tzdata util-linux mount"

	base="apt"

	if doing_variant fakechroot; then
		# ldd.fake needs binutils
		required="$required binutils"
	fi

	case $MIRRORS in
	    https://*)
		base="$base apt-transport-https ca-certificates"
		;;
	esac
}

first_stage_install () {
	extract $required

	mkdir -p "$TARGET/var/lib/dpkg"
	: >"$TARGET/var/lib/dpkg/status"
	: >"$TARGET/var/lib/dpkg/available"

	setup_etc
	if [ ! -e "$TARGET/etc/fstab" ]; then
		echo '# UNCONFIGURED FSTAB FOR BASE SYSTEM' > "$TARGET/etc/fstab"
		chown 0:0 "$TARGET/etc/fstab"; chmod 644 "$TARGET/etc/fstab"
	fi

	setup_devices

	x_feign_install () {
		local pkg="$1"
		local deb="$(debfor $pkg)"
		local ver="$(extract_deb_field "$TARGET/$deb" Version)"

		mkdir -p "$TARGET/var/lib/dpkg/info"

		echo \
"Package: $pkg
Version: $ver
Maintainer: unknown
Status: install ok installed" >> "$TARGET/var/lib/dpkg/status"

		touch "$TARGET/var/lib/dpkg/info/${pkg}.list"
	}

	x_feign_install dpkg
}

second_stage_install () {
	setup_dynamic_devices

	x_core_install () {
		smallyes '' | in_target dpkg --force-depends --install $(debfor "$@")
	}

	p () {
		baseprog="$(($baseprog + ${1:-1}))"
	}

	if doing_variant fakechroot; then
		setup_proc_fakechroot
	else
		setup_proc
		in_target /sbin/ldconfig
	fi

	DEBIAN_FRONTEND=noninteractive
	DEBCONF_NONINTERACTIVE_SEEN=true
	export DEBIAN_FRONTEND DEBCONF_NONINTERACTIVE_SEEN

	baseprog=0
	bases=7

	p; progress $baseprog $bases INSTCORE "Installing core packages" #1
	info INSTCORE "Installing core packages..."

	p; progress $baseprog $bases INSTCORE "Installing core packages" #2
	ln -sf mawk "$TARGET/usr/bin/awk"
	x_core_install base-passwd
	x_core_install base-files
	p; progress $baseprog $bases INSTCORE "Installing core packages" #3
	x_core_install dpkg

	if [ ! -e "$TARGET/etc/localtime" ]; then
		ln -sf /usr/share/zoneinfo/UTC "$TARGET/etc/localtime"
	fi

	if doing_variant fakechroot; then
		install_fakechroot_tools
	fi

	p; progress $baseprog $bases INSTCORE "Installing core packages" #4
	x_core_install $LIBC

	p; progress $baseprog $bases INSTCORE "Installing core packages" #5
	x_core_install perl-base

	p; progress $baseprog $bases INSTCORE "Installing core packages" #6
	rm "$TARGET/usr/bin/awk"
	x_core_install mawk

	p; progress $baseprog $bases INSTCORE "Installing core packages" #7
	if doing_variant -; then
		x_core_install debconf
	fi

	baseprog=0
	bases=$(set -- $required; echo $#)

	info UNPACKREQ "Unpacking required packages..."

	exec 7>&1

	smallyes '' |
		(repeatn 5 in_target_failmsg UNPACK_REQ_FAIL_FIVE "Failure while unpacking required packages.  This will be attempted up to five times." "" \
		dpkg --status-fd 8 --force-depends --unpack $(debfor $required) 8>&1 1>&7 || echo EXITCODE $?) |
		dpkg_progress $baseprog $bases UNPACKREQ "Unpacking required packages" UNPACKING

	info CONFREQ "Configuring required packages..."

	echo \
"#!/bin/sh
exit 101" > "$TARGET/usr/sbin/policy-rc.d"
	chmod 755 "$TARGET/usr/sbin/policy-rc.d"

	mv "$TARGET/sbin/start-stop-daemon" "$TARGET/sbin/start-stop-daemon.REAL"
	echo \
"#!/bin/sh
echo
echo \"Warning: Fake start-stop-daemon called, doing nothing\"" > "$TARGET/sbin/start-stop-daemon"
	chmod 755 "$TARGET/sbin/start-stop-daemon"

	setup_dselect_method apt

	smallyes '' |
		(in_target_failmsg CONF_REQ_FAIL "Failure while configuring required packages." "" \
		dpkg --status-fd 8 --configure --pending --force-configure-any --force-depends 8>&1 1>&7 || echo EXITCODE $?) |
		dpkg_progress $baseprog $bases CONFREQ "Configuring required packages" CONFIGURING

	baseprog=0
	bases="$(set -- $base; echo $#)"

	info UNPACKBASE "Unpacking the base system..."

	setup_available $required $base
	done_predeps=
	while predep=$(get_next_predep); do
		# We have to resolve dependencies of pre-dependencies manually because
		# dpkg --predep-package doesn't handle this.
		predep=$(without "$(without "$(resolve_deps $predep)" "$required")" "$done_predeps")
		# XXX: progress is tricky due to how dpkg_progress works
		# -- cjwatson 2009-07-29
		p; smallyes '' |
		in_target dpkg --force-overwrite --force-confold --skip-same-version --install $(debfor $predep)
		base=$(without "$base" "$predep")
		done_predeps="$done_predeps $predep"
	done

	smallyes '' |
		(repeatn 5 in_target_failmsg INST_BASE_FAIL_FIVE "Failure while installing base packages.  This will be re-attempted up to five times." "" \
		dpkg --status-fd 8 --force-overwrite --force-confold --skip-same-version --unpack $(debfor $base) 8>&1 1>&7 || echo EXITCODE $?) |
		dpkg_progress $baseprog $bases UNPACKBASE "Unpacking base system" UNPACKING

	info CONFBASE "Configuring the base system..."

	smallyes '' |
		(repeatn 5 in_target_failmsg CONF_BASE_FAIL_FIVE "Failure while configuring base packages.  This will be re-attempted up to five times." "" \
		dpkg --status-fd 8 --force-confold --skip-same-version --configure -a 8>&1 1>&7 || echo EXITCODE $?) |
		dpkg_progress $baseprog $bases CONFBASE "Configuring base system" CONFIGURING

	mv "$TARGET/sbin/start-stop-daemon.REAL" "$TARGET/sbin/start-stop-daemon"
	rm -f "$TARGET/usr/sbin/policy-rc.d"

	progress $bases $bases CONFBASE "Configuring base system"
	info BASESUCCESS "Base system installed successfully."
}
EOF
chmod +x /usr/share/debootstrap/scripts/bookworm

cat > /root/start.sh << 'EOL'

ROOT=$(cd "$(dirname "$0")" && TMPDIR="$(pwd)" mktemp -d)

TARGET=${1:?Specify the target filename}
DIST=${2:-stable}
PLATFORM=${3:-$(dpkg --print-architecture)}

LOGFILE=${TARGET}.log

:>"$LOGFILE"
exec >  >(tee -ia "$LOGFILE")
exec 2> >(tee -ia "$LOGFILE" >&2)

DEBOOTSTRAP_DIR="$ROOT"/debootstrap
mkdir -p $DEBOOTSTRAP_DIR
cp -a /usr/share/debootstrap/* "$DEBOOTSTRAP_DIR"
cp -a /usr/share/keyrings/debian-archive-keyring.gpg "$DEBOOTSTRAP_DIR"

KEYRING=$DEBOOTSTRAP_DIR/debian-archive-keyring.gpg

use_qemu_static() {
    [[ "$PLATFORM" == "arm64" && ! ( "$(uname -m)" == *arm* || "$(uname -m)" == *aarch64* ) ]]
}

export DEBIAN_FRONTEND=noninteractive

debootstrap_arch_args=( )

if use_qemu_static ; then
    debootstrap_arch_args+=( --arch "$PLATFORM" )
fi

rootfsDir="$ROOT"/rootfs
mkdir -p $rootfsDir

# debootstrap first-stage (downloading debs phase) dont support multiplesuits/multipcomponets (just singlemainsuit/multipcomponets)
# but we can divide debootstrap to two explict steps, and apply full-mirror fix and chroot apt-get upgrade after second_stage
repo_url="https://snapshot.debian.org/archive/debian/20250426T000000Z"
sec_repo_url="https://snapshot.debian.org/archive/debian-security/20250426T000000Z"

echo "Building base in $rootfsDir"
DEBOOTSTRAP_DIR="$DEBOOTSTRAP_DIR" debootstrap "${debootstrap_arch_args[@]}"  --keyring "$KEYRING" --variant container --foreign "${DIST}" "$rootfsDir" "$repo_url"

# get path to "chroot" in our current PATH
chrootPath="$(type -P chroot)"
rootfs_chroot() {
    # "chroot" doesn't set PATH, so we need to set it explicitly to something our new debootstrap chroot can use appropriately!
    # set PATH and chroot away!
    PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            "$chrootPath" "$rootfsDir" "$@"

}

if use_qemu_static ; then
    echo "Setting up qemu static in chroot"
    usr_bin_modification_time=$(stat -c %y "$rootfsDir"/usr/bin)
    if [ -f "/usr/bin/qemu-aarch64-static" ]; then
        find /usr/bin/ -type f -name 'qemu-*-static' -exec cp {} "$rootfsDir"/usr/bin/. \;
    else
        echo "Cannot find aarch64 qemu static. Aborting..." >&2
        exit 1
    fi
    touch -d "$usr_bin_modification_time" "$rootfsDir"/usr/bin
fi

rootfs_chroot bash debootstrap/debootstrap --second-stage

echo -e "deb ${repo_url} $DIST main" > "$rootfsDir/etc/apt/sources.list"
echo "deb ${repo_url} $DIST-updates main" >> "$rootfsDir/etc/apt/sources.list"
echo "deb ${sec_repo_url} $DIST-security main" >> "$rootfsDir/etc/apt/sources.list"

rootfs_chroot apt-get update -o Acquire::Check-Valid-Until=false
rootfs_chroot apt-get upgrade -y -o Dpkg::Options::="--force-confdef"

rootfs_chroot dpkg -l | tee "$TARGET.manifest"

outDir="$rootfsDir"/packages_dump
mkdir -p "$outDir/main" "$outDir/main-updates" "$outDir/main-security"

cat > "$rootfsDir"/1.sh <<-'EOF'
#!/bin/bash
set -e

dumpdir="packages_dump"
urlencode() {
    local string="${1}"
    local encoded=""
    local pos c o
    for ((pos=0 ; pos<${#string} ; pos++)); do
        c=${string:$pos:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) o="${c}" ;;
            *) o=$(printf '%%%02X' "'$c") ;;
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 1. 分析并输出三列，然后移动文件
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' | while read pkg ver arch; do
  ver_no_epoch=$(echo "$ver" | sed 's/^[0-9]\+://')
  debfile_no_epoch="${pkg}_${ver_no_epoch}_${arch}.deb"
  ver_urlenc="${ver/:/%3a}"
  debfile_epoch_urlenc="${pkg}_${ver_urlenc}_${arch}.deb"
  debpath="/var/cache/apt/archives/${debfile_epoch_urlenc}"

  origin=$(apt-cache policy "$pkg" | grep -E 'http.*main' | head -n1)
  if echo "$origin" | grep -q "security"; then
    repo="main-security"
  elif echo "$origin" | grep -q "updates"; then
    repo="main-updates"
  else
    repo="main"
  fi
  echo -e "${pkg}\t${debfile_no_epoch}\t${repo}"

  if [ -f "$debpath" ]; then
    mv "$debpath" "$dumpdir/$repo/"
  else
    echo "Failed $debfile_epoch_urlenc" && exit 1
  fi

done

apt-get update -o Acquire::Check-Valid-Until=false
apt-get install -y curl

arch=$(dpkg --print-architecture)
url_check() {
  http_status=$(curl -o /dev/null -s -w "%{http_code}\n" "$1")
  if [ "$http_status" != 200 -a "$http_status" != 301 -a "$http_status" != 302 -a "$http_status" != 307 -a "$http_status" != 308 ]; then
    echo "1"
  fi
}
extract_mini_release() {
    local input="$1"
    local output="$2"

    awk -v arch="$arch" '
    BEGIN{in_md5=0;in_sha256=0;}
    /^Architectures:/ { print "Architectures: all " arch; next }
    /^Components:/ { print "Components: main"; next }

    /^Origin:/ || /^Label:/ || /^Suite:/ || /^Version:/ || /^Codename:/ ||
    /^Changelogs:/ || /^Date:/ || /^Acquire-By-Hash:/ || /^No-Support-for-Architecture-all:/ ||
    /^Description:/ { print; next }

    /^MD5Sum:/ { print; in_md5=1; next }
    in_md5 && (index($0, "main/binary-" arch "/")>0) { print; next }
    in_md5 && $0 ~ /^[A-Za-z]/ { in_md5=0; }

    /^SHA256:/ { print; in_sha256=1; next }
    in_sha256 && (index($0, "main/binary-" arch "/")>0) { print; next }
    in_sha256 && $0 ~ /^[A-Za-z]/ { in_sha256=0; }
    ' "$input" > "$output"
}

# 2. 解析 /etc/apt/sources.list，下载 Packages 和 Release 文件到对应子文件夹
grep -E '^deb ' /etc/apt/sources.list | while read line; do
  url=$(echo $line | awk '{print $2}')
  suite=$(echo $line | awk '{print $3}')
  component=$(echo $line | awk '{print $4}')

  # 只处理main相关仓库
  if [ "$component" != "main" ]; then
    continue
  fi
  # 判断repo类型
  if echo $url | grep -q "security" || echo "$suite" | grep -q "security"; then
    repo="main-security"
  elif echo $suite | grep -q "updates"; then
    repo="main-updates"
  else
    repo="main"
  fi

  # binary-arch/package is superset of binary-all/package, so always get binary-arch/package files
  pkgurl="${url}/dists/${suite}/${component}/binary-${arch}/Packages.gz"
  pkgext=".gz"
  if [ "$(url_check "$pkgurl")" = "1" ]; then
    pkgurl="${url}/dists/${suite}/${component}/binary-${arch}/Packages.xz"
    pkgext=".xz"
  fi
  releaseurl="${url}/dists/${suite}/Release"
  curl -sSL "$pkgurl" -o "$dumpdir/$repo/Packages""$pkgext"_ori || { echo "Failed $pkgurl" && exit 1; }
  curl -sSL "$releaseurl" -o "$dumpdir/$repo/Release_ori" || { echo "Failed $releaseurl" && exit 1; }
  extract_mini_release "$dumpdir/$repo/Release_ori" "$dumpdir/$repo/Release"

done
EOF

echo "composite a debmini repo"
rootfs_chroot bash 1.sh
echo "Total size"
du -skh "$outDir"
echo "Built in $outDir"


EOL
chmod +x /root/start.sh


echo "Cleaning up"
silent apt-get -y autoremove
silent apt-get -y autoclean
echo "Cleaned"

##############
