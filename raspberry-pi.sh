#!/usr/bin/env bash
#
# Kali Linux ARM build-script for Raspberry Pi 2/3/4/400 (32-bit)
# Source: https://gitlab.com/kalilinux/build-scripts/kali-arm
#
# This is a supported device - which you can find pre-generated images on: https://www.kali.org/get-kali/
# More information: https://www.kali.org/docs/arm/raspberry-pi-2/
#

# Hardware model
hw_model=${hw_model:-"raspberry-pi"}

# Architecture
architecture=${architecture:-"armhf"}

# Desktop manager (xfce, gnome, i3, kde, lxde, mate, e17 or none)
desktop=${desktop:-"xfce"}

# Load default base_image configs
source ./common.d/base_image.sh

# Network configs
basic_network
add_interface eth0

# Third stage
cat <<EOF >> "${work_dir}"/third-stage
status_stage3 'Copy rpi services'
cp -p /bsp/services/rpi/*.service /etc/systemd/system/

status_stage3 'Script mode wlan monitor START/STOP'
install -m755 /bsp/scripts/{monstart,monstop} /usr/bin/

status_stage3 'Build RaspberryPi utils'
git clone --quiet https://github.com/raspberrypi/utils /usr/src/utils
cd /usr/src/utils/
# Without gcc/make, this will fail on slim images.
apt-get install -y cmake device-tree-compiler libfdt-dev build-essential
cmake .
make
make install

status_stage3 'Install the kernel'
if [[ "${architecture}" == "arm64" ]]; then
eatmydata apt-get -y -q install raspi-firmware linux-image-rpi-2712 linux-image-rpi-v8 linux-headers-rpi-2712 linux-headers-rpi-v8 brcmfmac-nexmon-dkms pi-bluetooth
else
eatmydata apt-get -y -q install raspi-firmware linux-image-rpi-v7 linux-image-rpi-v7l linux-headers-rpi-v7 linux-headers-rpi-v7l brcmfmac-nexmon-dkms pi-bluetooth
fi

status_stage3 'Create symlink for Raspberry Pi 4 Compute Module'
pushd /lib/firmware/brcm/ > /dev/null
ln -s ./brcmfmac43455-sdio.raspberrypi,4-model-b.txt ./brcmfmac43455-sdio.raspberrypi,4-compute-module.txt
popd > /dev/null

status_stage3 'Copy script for handling wpa_supplicant file'
install -m755 /bsp/scripts/copy-user-wpasupplicant.sh /usr/bin/

status_stage3 'Enable copying of user wpa_supplicant.conf file'
systemctl enable copy-user-wpasupplicant

status_stage3 'Enabling ssh by putting ssh or ssh.txt file in /boot'
systemctl enable enable-ssh

status_stage3 'Disable haveged daemon'
systemctl disable haveged

status_stage3 'Fixup wireless-regdb signature'
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream

status_stage3 'Enable hciuart and bluetooth'
systemctl enable hciuart
systemctl enable bluetooth

status_stage3 'Set up cloud-init'
install -m644 /bsp/cloudinit/user-data /boot/firmware
install -m644 /bsp/cloudinit/meta-data /boot/firmware
install -m644 /bsp/cloudinit/cloud.cfg /etc/cloud/
# This snippet overrides config which sets the default user so punt it.
rm /etc/cloud/cloud.cfg.d/20_kali.cfg
mkdir -p /var/lib/cloud/seed/nocloud-net
ln -s /boot/firmware/user-data /var/lib/cloud/seed/nocloud-net/user-data
ln -s /boot/firmware/meta-data /var/lib/cloud/seed/nocloud-net/meta-data
ln -s /boot/firmware/network-config /var/lib/cloud/seed/nocloud-net/network-config
systemctl enable cloud-init-hotplugd.socket
systemctl enable cloud-init-main.service
# Attempt to work around a bug where the network-config filename is written
# incorrectly if the file does not exit previously
# https://github.com/raspberrypi/rpi-imager/issues/945
touch /boot/firmware/network-config
# HACK: Make sure /boot/firmware is also mounted before cloud-init-local starts
sed -i -e 's|RequiresMountsFor=.*|RequiresMountsFor=/var/lib/cloud /boot/firmware|' /usr/lib/systemd/system/cloud-init-local.service
# HACK: Disable rpi-resizerootfs service
systemctl disable rpi-resizerootfs.service
# New service to attempt to fix up the rpi-imager hardcoding
systemctl enable rpi-imager-fixup.service

status_stage3 'Copy xorg config snippet'
mkdir -p /etc/X11/xorg.conf.d/
install -m644 /bsp/xorg/99-vc4.conf /etc/X11/xorg.conf.d/
EOF

# Run third stage
include third_stage

# Firmware needed for the wifi
cd "${work_dir}"
status 'Clone Wi-Fi/Bluetooth firmware'
git clone --quiet --depth 1 https://github.com/rpi-distro/firmware-nonfree
cd firmware-nonfree/debian/config/brcm80211
rsync -HPaz brcm "${work_dir}"/lib/firmware/
rsync -HPaz cypress "${work_dir}"/lib/firmware/
cd "${work_dir}"/lib/firmware/cypress
ln -sf cyfmac43455-sdio-standard.bin cyfmac43455-sdio.bin
rm -rf "${work_dir}"/firmware-nonfree

# bluetooth firmware
wget -q 'https://github.com/RPi-Distro/bluez-firmware/raw/bookworm/debian/firmware/broadcom/BCM4345C0.hcd' -O "${work_dir}"/lib/firmware/brcm/BCM4345C0.hcd

cd "${repo_dir}/"

# Clean system
include clean_system

# Calculate the space to create the image and create
make_image

# Create the disk partitions
status "Create the disk partitions"
parted -s "${image_dir}/${image_name}.img" mklabel msdos
parted -s "${image_dir}/${image_name}.img" mkpart primary fat32 1MiB "${bootsize}"MiB
parted -s -a minimal "${image_dir}/${image_name}.img" mkpart primary "$fstype" "${bootsize}"MiB 100%

# Set the partition variables
make_loop

# Create file systems
mkfs_partitions

# Make fstab
make_fstab

# Configure Raspberry Pi firmware (before rsync)
include rpi_firmware

sed -i -e 's/net.ifnames=0/net.ifnames=0 ds=nocloud/' "${work_dir}"/boot/firmware/cmdline.txt

# RaspberryPi devices mount the first partition on /boot/firmware
sed -i -e 's|/boot|/boot/firmware|' "${work_dir}"/etc/fstab

# Create the dirs for the partitions and mount them
status "Create the dirs for the partitions and mount them"
mkdir -p "${base_dir}"/root/

if [[ $fstype == ext4 ]]; then
    mount -t ext4 -o noatime,data=writeback,barrier=0 "${rootp}" "${base_dir}"/root

else
    mount "${rootp}" "${base_dir}"/root

fi

mkdir -p "${base_dir}"/root/boot/firmware
mount "${bootp}" "${base_dir}"/root/boot/firmware

status "Rsyncing rootfs into image file"
rsync -HPavz -q --exclude boot/firmware "${work_dir}"/ "${base_dir}"/root/
sync

status "Rsyncing boot into image file (/boot)"
rsync -rtx -q "${work_dir}"/boot/firmware "${base_dir}"/root/boot
sync

# Load default finish_image configs
include finish_image
