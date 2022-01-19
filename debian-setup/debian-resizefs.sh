#!/bin/bash
# Resize root and swap partitions and create a new home partition.
#
# VERSION       :1.0.2
# DATE          :2022-01-19
# URL           :https://github.com/senhalil/debian-server-tools/blob/main/debian-setup/debian-resizefs.sh
# AUTHOR        :Viktor Szépe <viktor@szepe.net>, Halil Sen <halil@mapotempo.com>
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+


ROOT_SIZE="75G" # New size of root filesystem
SWAP_SIZE="24G" # 1.5x of RAM if hibernation is allowed https://docs.fedoraproject.org/en-US/Fedora/26/html/Installation_Guide/sect-installation-gui-manual-partitioning-recommended.html
HOME_NAME="home" # This will be created with the remaining free space of the disk


# No need to touch anything down below unless there is an issue with the script. \
# It automatically identifies Volume Group name (vg_name) 
# and the internal device mapper names (lv_dm_path) for root and swap partitions
VOLUME_GROUP_NAME="$(vgs --noheadings -o vg_name | xargs)"
ROOT_DEVICE="$(lvs --noheadings -o lv_dm_path ${VOLUME_GROUP_NAME} | grep root | xargs)"
SWAP_DEVICE="$(lvs --noheadings -o lv_dm_path ${VOLUME_GROUP_NAME} | grep swap | xargs)"
HOME_DEVICE="$(echo ${ROOT_DEVICE} | sed -s "s/root/${HOME_NAME}/")"


# Check current filesystem type
ROOT_FS_TYPE="$(sed -n -e 's|^/dev/\S\+ / \(ext4\) .*$|\1|p' /proc/mounts)"
test "$ROOT_FS_TYPE" == ext4 || echo "ROOT_FS_TYPE=${ROOT_FS_TYPE} is not ext4" || exit 100

# Find the encrypted and decrypted physical partitions
DECRYPTED_LUKS_PARTITION_NAME="$(cat /etc/crypttab | cut -f1 -d " ")"
test "$(echo $DECRYPTED_LUKS_PARTITION_NAME | cut -f2 -d "_")" == crypt || echo "Cannot detect luks partition name" || exit 100  
LUKS_PARTITION="$(fdisk -l | grep "$(echo $DECRYPTED_LUKS_PARTITION_NAME | cut -f1 -d "_") " | cut -f1 -d " ")"

echo "******************************************************************************************************************"
echo -e "ROOT_DEVICE=\"${ROOT_DEVICE}\" \t\t will be resized to \t ROOT_SIZE=\"${ROOT_SIZE}\""
echo -e "SWAP_DEVICE=\"${SWAP_DEVICE}\" \t\t will be resised to \t SWAP_SIZE=\"${SWAP_SIZE}\""
echo -e "HOME_DEVICE=\"${HOME_DEVICE}\" \t\t will be generated with the remaning free space in \t VOLUME_GROUP_NAME=\"${VOLUME_GROUP_NAME}\""
echo "with:"
echo -e "LUKS_PARTITION=\"${LUKS_PARTITION}\""
echo -e "DECRYPTED_LUKS_PARTITION_NAME=\"${DECRYPTED_LUKS_PARTITION_NAME}\""
echo "******************************************************************************************************************"

read -rp $'If the settings look okay, press [Enter] key to continue!\nOtherwise, quit with [Ctrl+C].'


echo "******************Copying the needed programs (copy_exec)*********************************************************"
# Copy e2fsck and resize2fs to initrd
cat > /etc/initramfs-tools/hooks/resize2fs <<"EOF"
#!/bin/sh

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /usr/share/initramfs-tools/hook-functions
copy_exec /bin/cp         /bin
copy_exec /bin/mv         /bin
copy_exec /bin/mkdir      /bin
copy_exec /bin/mount      /bin
copy_exec /bin/umount     /bin

copy_exec /sbin/cryptsetup /sbin
copy_exec /sbin/e2fsck     /sbin
copy_exec /sbin/fsadm      /sbin
copy_exec /sbin/lvcreate   /sbin
copy_exec /sbin/lvresize   /sbin
copy_exec /sbin/mkfs.ext4  /sbin
copy_exec /sbin/mkswap     /sbin
copy_exec /sbin/resize2fs  /sbin
copy_exec /sbin/vgchange   /sbin
EOF
chmod +x /etc/initramfs-tools/hooks/resize2fs


echo "******************Creating the script to resize root, swap partition and create a home partition******************"
# Execute resize2fs before mounting root filesystem
cat > /etc/initramfs-tools/scripts/init-premount/resize <<EOF
#!/bin/sh

PREREQ=""

prereqs() {
    echo "\$PREREQ"
}

case "\$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

echo ""
echo "*********** Unlocking the luks partition *******************************"
/sbin/cryptsetup luksOpen $LUKS_PARTITION $DECRYPTED_LUKS_PARTITION_NAME

echo "*********** Making sure LVM volumes are activated **********************"
/sbin/vgchange -q -a y                                  || echo "vgchange ERROR: \$?  "

echo "*********** Checking and resizing root *********************************"
/sbin/e2fsck -y -v -f $ROOT_DEVICE                      || echo "e2fsck ERROR: \$?  "
/sbin/resize2fs -d 8 $ROOT_DEVICE $ROOT_SIZE            || echo "resize2fs ERROR: \$?  "
/sbin/lvresize -q -y -n -f -L $ROOT_SIZE $ROOT_DEVICE   || echo "lvresize ERROR: \$?  "

echo "*********** Resizing swap and setting it up ****************************" 
/sbin/lvresize -q -y -n -f -L $SWAP_SIZE $SWAP_DEVICE   || echo "lvresize ERROR: \$?  "
/sbin/mkswap $SWAP_DEVICE                               || echo "mkswap ERROR: \$?  "

echo "*********** Creating the new home and formating it *********************"
/sbin/lvcreate -q -y -l 100%FREE $VOLUME_GROUP_NAME -n $HOME_NAME  || echo "lvcreate ERROR: \$?  "
/sbin/mkfs.ext4 -q $HOME_DEVICE                                    || echo "mkfs ERROR: \$?  "

echo "*********** Mounting the root and moving the existing files ************"
/bin/mkdir /mnt-root                                    || echo "mkdir ERROR: \$?  "
/bin/mount $ROOT_DEVICE /mnt-root                       || echo "mount ERROR: \$?  " 
/bin/mv /mnt-root/$HOME_NAME /mnt-root/old_$HOME_NAME   || echo "mv ERROR: \$?  "
/bin/mkdir /mnt-root/$HOME_NAME                         || echo "mkdir ERROR: \$?  "

echo "*********** Mounting the new home and copying the existing files *******"
/bin/mount $HOME_DEVICE /mnt-root/$HOME_NAME                       || echo "mount ERROR: \$?  "
/bin/cp -a /mnt-root/old_$HOME_NAME/. /mnt-root/$HOME_NAME         || echo "cp ERROR: \$?  "

echo "*********** Adding the new volume as new home to fstab *****************"
echo "$HOME_DEVICE  /$HOME_NAME           ext4    defaults         0       2" >> /mnt-root/etc/fstab

echo "*********** Unmounting the new home and the root ***********************"
/bin/umount /mnt-root/$HOME_NAME                        || echo "umount ERROR: \$?  "
/bin/umount /mnt-root                                   || echo "umount ERROR: \$?  "

read -p "Finished! Don't forget to check if there are any errors! Press [Enter] key to continue! "
EOF
chmod +x /etc/initramfs-tools/scripts/init-premount/resize


echo "******************Removing quite and splash from /etc/default/grub************************************************" 
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
update-grub

echo "******************Regenerate initrd (can take a few seconds)******************************************************"
update-initramfs -u

echo "******************Remove initramfs files and remove GRUB modifications********************************************"
rm -f /etc/initramfs-tools/hooks/resize2fs /etc/initramfs-tools/scripts/init-premount/resize
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub


echo "******************************************************************************************************************"

read -rp $'If there are no errors, press [Enter] key to continue!\nOtherwise, quit with [Ctrl+C]!\n\n(\"Possible missing firmware\" warnings can be ignored: they are about CPUs/GPUs that do not exist on the current system)'


echo "******************************************************************************************************************"
read -rp $'!IMPORTANT!\n\nAfter the reboot, the following commands need to be executed (to put the initramfs and grub to their original states):\nupdate-initramfs -u\nupdate-grub\n\nand /old_'"$HOME_NAME"$' folder can be deleted (rm -r /old_'"$HOME_NAME"$') after verifying that everything is in order.\n\nIf you are ready, press [Enter] key to continue with reboot.'

echo "reboot"
reboot






# # AFTER THE REBOOT #
# echo "Reset GRUB and initramfs"
# update-initramfs -u
# update-grub
# echo "Delete home backup (if everything is in order)"
# rm -r /old_$HOME_NAME
