#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash
source $base_dir/etc/settings.bash

# do nothing if the variant isn't fips
if [ "${stemcell_operating_system_variant}" != "fips" ]; then
    echo "Skipping base_apt_fips given that this is not a 'fips' variant"
    exit 0
else
    echo "FIPS variant detected. setting up FIPS"
fi


if [ -z "${UBUNTU_ADVANTAGE_TOKEN}" ]; then
    echo "'fips' variant detected but \$UBUNTU_ADVANTAGE_TOKEN not given."
    echo "please provide a UBUNTU_ADVANTAGE_TOKEN to be able to build 'fips' variants."
    exit 1
fi


function ua_attach() {
    local chroot=$1

    # TEMPORARY. PRIVATE REPO ONLY. DO NOT MERGE
    cp /opt/bosh/key.asc ${chroot}/etc/apt/trusted.gpg.d/7CA1F5946D641569F6169DA6185BA77D9DB344C3.asc
    cat /opt/bosh/fips_sources.txt >> ${chroot}/etc/apt/sources.list
    run_in_chroot ${chroot} "apt-get update"
    # END TEMPORARY


    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-get install --assume-yes ubuntu-advantage-tools"

    # overwrite the cloud type so the correct kernel gets installed
    # FIXME: do not hardcode aws here!
    echo "settings_overrides:" >> ${chroot}/etc/ubuntu-advantage/uaclient.conf
    echo "  cloud_type: aws" >> ${chroot}/etc/ubuntu-advantage/uaclient.conf
    run_in_chroot ${chroot} "ua attach --no-auto-enable ${UBUNTU_ADVANTAGE_TOKEN}"
}


function ua_detach() {
    local chroot=$1

    # TEMPORARY. PRIVATE REPO ONLY. DO NOT MERGE
    rm ${chroot}/etc/apt/trusted.gpg.d/7CA1F5946D641569F6169DA6185BA77D9DB344C3.asc
    sed -i '/fips-under-certification/d' ${chroot}/etc/apt/sources.list
    # END TEMPORARY

    run_in_chroot ${chroot} "ua detach --assume-yes"
    # cleanup (to not leak the token into an image)
    run_in_chroot ${chroot} "rm -rf /var/lib/ubuntu-advantage/private/*"
    run_in_chroot ${chroot} "rm /var/log/ubuntu-advantage.log"
}


function ua_enable_fips() {
    local chroot=$1
    # Uncomment the following line when fips is available in ua client
    # run_in_chroot ${chroot} "ua enable --assume-yes fips"
}


function install_and_hold_packages() {
    local chroot=$1
    local pkgs=$2
    echo "Installing and holding packages: ${pkgs}"
    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-get install --assume-yes ${pkgs}"

    # NOTE:This package hold creates problems for users wanting to install
    # updates from the FIPS update PPA. However this hold is required
    # until there is a FIPS meta-package which can ensure higher versioned,
    # non-FIPS packages are not selected to replace these.
    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-mark hold ${pkgs}"
}


# taken from https://git.launchpad.net/livecd-rootfs/tree/live-build/ubuntu-cpc/hooks.d/chroot/999-cpc-fixes.chroot#n125
psuedo_grub_probe() {
    cat <<"PSUEDO_GRUB_PROBE"
#!/bin/sh
Usage() {
   cat <<EOF
Usage: euca-psuedo-grub-probe
   this is a wrapper around grub-probe to provide the answers for an ec2 guest
EOF
}
bad_Usage() { Usage 1>&2; fail "$@"; }
short_opts=""
long_opts="device-map:,target:,device"
getopt_out=$(getopt --name "${0##*/}" \
   --options "${short_opts}" --long "${long_opts}" -- "$@") &&
   eval set -- "${getopt_out}" ||
   bad_Usage
device_map=""
target=""
device=0
arg=""
while [ $# -ne 0 ]; do
   cur=${1}; next=${2};
   case "$cur" in
       --device-map) device_map=${next}; shift;;
       --device) device=1;;
       --target) target=${next}; shift;;
       --) shift; break;;
   esac
   shift;
done
arg=${1}
case "${target}:${device}:${arg}" in
    device:*:/*) echo "/dev/sda1"; exit 0;;
    fs:*:*) echo "ext2"; exit 0;;
    partmap:*:*)
      # older versions of grub (lucid) want 'part_msdos' written
      # rather than 'msdos'
      legacy_pre=""
      grubver=$(dpkg-query --show --showformat '${Version}\n' grub-pc 2>/dev/null) &&
         dpkg --compare-versions "${grubver}" lt 1.98+20100804-5ubuntu3 &&
         legacy_pre="part_"
      echo "${legacy_pre}msdos";
      exit 0;;
  abstraction:*:*) echo ""; exit 0;;
  drive:*:/dev/sda) echo "(hd0)";;
  drive:*:/dev/sda*) echo "(hd0,1)";;
  fs_uuid:*:*) exit 1;;
esac
PSUEDO_GRUB_PROBE
}


function mock_grub_probe() {
    local chroot=$1
    # make sure /usr/sbin/grub-probe is installed in the chroot
    DEBIAN_FRONTEND=noninteractive run_in_chroot ${chroot} "apt-get install --assume-yes grub-common"
    gprobe="${chroot}/usr/sbin/grub-probe"
    if [ -f "${gprobe}" ]; then
        mv "${gprobe}" "${gprobe}.dist"
    fi
    psuedo_grub_probe > "${gprobe}"
    chmod 755 "${gprobe}"
}


function unmock_grub_probe() {
    local chroot=$1
    gprobe="${chroot}/usr/sbin/grub-probe"
    if [ -f "${gprobe}.dist" ]; then
        mv "${gprobe}.dist" "${gprobe}"
    fi
}


function write_fips_cmdline_conf() {
    cat << "EOF" >> "${chroot}/etc/default/grub.d/99-fips.cfg"
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT fips=1"
EOF
}

# those packages need to be installed from the FIPS repo and hold
FIPS_PKGS="openssh-client openssh-server openssl libssl3 libssl-dev linux-aws-fips linux-headers-aws-fips linux-image-aws-fips linux-modules-extra-5.15.0-1042-aws-fips fips-initramfs libgcrypt20 libgcrypt20-hmac libgcrypt20-dev fips-initramfs"

echo "Setting up Ubuntu Advantage ..."

mock_grub_probe "${chroot}"
ua_attach "${chroot}"
ua_enable_fips "${chroot}"
write_fips_cmdline_conf
install_and_hold_packages "${chroot}" "${FIPS_PKGS}"
ua_detach "${chroot}"

unmock_grub_probe "${chroot}"
