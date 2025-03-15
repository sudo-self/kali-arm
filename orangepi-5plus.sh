#!/usr/bin/env bash
#
# Kali Linux ARM build-script for OrangePi 5 Plus (64-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a community script - you will need to generate your own image to use
# More information: https://www.kali.org/docs/arm/orangepi-5plus/
#

# Hardware model
hw_model=${hw_model:-"orangepi-5plus"}

# Architecture
architecture=${architecture:-"arm64"}

# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)
desktop=${desktop:-"xfce"}

# Load default base_image configs
source ./common.d/base_image.sh

# Network configs
basic_network
add_interface eth0
add_interface eth1

# Third stage
cat <<EOF >>"${work_dir}"/third-stage
status_stage3 'Install kali-sbc package'
eatmydata apt-get install -y u-boot-menu u-boot-tools

# We need "file" for the kernel scripts we run, and it won't be installed if you pass --slim
# So we always make sure it's installed. Also, for hdmi audio, we need to run commands
# so install alsa-utils for amixer and alsactl availability.
eatmydata apt-get install -y file alsa-utils

# Note: This just creates an empty /boot/extlinux/extlinux.conf for us to use
# later when we install the kernel, and then fixup further down
status_stage3 'Run u-boot-update'
u-boot-update

status_stage3 'Add needed extlinux and uenv scripts'
cp /bsp/scripts/orangepi-5plus/update_extlinux.sh /usr/local/sbin/
cp /bsp/scripts/orangepi-5plus/update_uenv.sh /usr/local/sbin/
cp /bsp/scripts/orangepi-5plus/config.txt /boot/
mkdir -p /etc/kernel/postinst.d
# Be sure to update the cmdline with the correct UUID after creating the img.
cp /bsp/scripts/orangepi-5plus/cmdline /etc/kernel
cp /bsp/scripts/orangepi-5plus/extlinux /etc/default/extlinux
cp /bsp/scripts/orangepi-5plus/zz-uncompress /etc/kernel/postinst.d/
cp /bsp/scripts/orangepi-5plus/zz-update-extlinux /etc/kernel/postinst.d/
cp /bsp/scripts/orangepi-5plus/zz-update-uenv /etc/kernel/postinst.d/

status_stage3 'Fixup wireless-regdb signature'
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream

status_stage3 'Remove cloud-init where it is not used'
eatmydata apt-get -y purge --autoremove cloud-init
EOF

# Run third stage
include third_stage

# Clean system
include clean_system

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section
status "Kernel stuff"
git clone --depth 1 -b orange-pi-5.10-rk3588 https://github.com/steev/linux.git ${work_dir}/usr/src/kernel
cd ${work_dir}/usr/src/kernel
git rev-parse HEAD >${work_dir}/usr/src/kernel-at-commit
touch .scmversion
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make steev_defconfig
make -j $(grep -c processor /proc/cpuinfo) bindeb-pkg
#make modules_install INSTALL_MOD_PATH=${work_dir}
#cp arch/arm64/boot/Image ${work_dir}/boot/
#cp arch/arm64/boot/dts/rockchip/*orangepi*.dtb ${work_dir}/boot/dtbs/
make mrproper
make steev_defconfig
cd ..

# Cross building kernel packages produces broken header packages
# so only install the headers if we're building on arm64
if [ "$(arch)" == 'aarch64' ]; then
    # We don't need to install the linux-libc-dev package, we just want kernel and headers
    rm linux-libc-dev*.deb
    # Temporary hack to work around dpkg statoverride user errors
    mv "${work_dir}"/var/lib/dpkg/statoverride "${work_dir}"/var/lib/dpkg/statoverride.bak
    dpkg --root "${work_dir}" -i linux-*.deb
    mv "${work_dir}"/var/lib/dpkg/statoverride.bak "${work_dir}"/var/lib/dpkg/statoverride

else
    # Temporary hack to work around dpkg statoverride user errors
    mv "${work_dir}"/var/lib/dpkg/statoverride "${work_dir}"/var/lib/dpkg/statoverride.bak
    dpkg --root "${work_dir}" -i linux-image-*.deb
    mv "${work_dir}"/var/lib/dpkg/statoverride.bak "${work_dir}"/var/lib/dpkg/statoverride

fi

cd "${repo_dir}/"

# Calculate the space to create the image and create
make_image

# Create the disk partitions
status "Create the disk partitions"
parted -s "${image_dir}/${image_name}.img" mklabel msdos
parted -s -a minimal "${image_dir}/${image_name}.img" mkpart primary ext4 5MiB 100%

# Set the partition variables
make_loop

# Create file systems
# Force root partition ext2 filesystem
mkfs_partitions

# Make fstab.
make_fstab

# Create the dirs for the partitions and mount them
status "Create the dirs for the partitions and mount them"
mkdir -p "${base_dir}"/root

if [[ $fstype == ext4 ]]; then
    mount -t ext4 -o noatime,data=writeback,barrier=0 "${rootp}" "${base_dir}"/root

else
    mount "${rootp}" "${base_dir}"/root

fi

status "Edit the extlinux.conf file to set root uuid and proper name"
# Ensure we don't have root=/dev/sda3 in the extlinux.conf which comes from running u-boot-menu in a cross chroot
# We do this down here because we don't know the UUID until after the image is created
sed -i -e "0,/append.*/s//append root=UUID=$(blkid -s UUID -o value ${rootp}) rootfstype=$fstype earlyprintk console=ttyS0,115200 console=tty1 console=both swiotlb=1 coherent_pool=1m ro rootwait/g" ${work_dir}/boot/extlinux/extlinux.conf
# And we remove the "GNU/Linux because we don't use it
sed -i -e "s|.*GNU/Linux Rolling|menu label Kali Linux|g" ${work_dir}/boot/extlinux/extlinux.conf

# And we need to edit the /etc/kernel/cmdline file as well
status "Edit cmdline"
sed -i -e "s/root=UUID=.*/root=UUID=$(blkid -s UUID -o value ${rootp})/" ${work_dir}/etc/kernel/cmdline

status "Set the default options in /etc/default/u-boot"
echo 'U_BOOT_MENU_LABEL="Kali Linux"' >>${work_dir}/etc/default/u-boot
echo 'U_BOOT_PARAMETERS="earlyprintk console=ttyAML0,115200 console=tty1 console=both swiotlb=1 coherent_pool=1m ro rootwait"' >>${work_dir}/etc/default/u-boot

status "Rsyncing rootfs into image file"
rsync -HPavz -q "${work_dir}"/ "${base_dir}"/root/
sync

cd "${repo_dir}/"
# Load default finish_image configs
include finish_image
