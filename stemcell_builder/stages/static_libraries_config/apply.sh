#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash
source $base_dir/lib/prelude_bosh.bash
source $base_dir/etc/settings.bash

cp -p "${assets_dir}/${DISTRIB_CODENAME}_static_libraries_list.txt" $chroot/var/vcap/bosh/etc/static_libraries_list
kernel_suffix="-generic"
if [[ "${DISTRIB_CODENAME}" == 'bionic' ]]; then
    major_kernel_version="5.4"
elif [[ "${DISTRIB_CODENAME}" == 'jammy' ]]; then
    if [ -z "${UBUNTU_ADVANTAGE_TOKEN}" ]; then
        major_kernel_version="6.2"
    else
        # FIPS kernel is 4.15
        major_kernel_version="5.15"
        # kernel_suffix="-aws-fips"
        kernel_suffix="-fips"
    fi
else
    major_kernel_version="4.15"
fi
kernel_version=$(find $chroot/usr/src/ -name "linux-headers-$major_kernel_version.*$kernel_suffix" | grep -o "[0-9].*-[0-9]*$kernel_suffix")
sed -i "s/__KERNEL_VERSION__/$kernel_version/g" $chroot/var/vcap/bosh/etc/static_libraries_list
