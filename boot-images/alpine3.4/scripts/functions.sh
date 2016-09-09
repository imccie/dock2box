ROOT="/mnt/sysimage"
DOCKER_ROOT="/mnt/docker"

INFO_COL="\033[1;32m"
WARN_COL="\033[0;33m"
FATAL_COL="\033[0;31m"
NO_COL='\033[0m'

# Print messages
info() {
    if [ "${KOPT_nocolor:-false}" == "true" ]; then
        printf "* $1\n"
    else
        printf "${INFO_COL}*${NO_COL} $1\n"
    fi
}

warn() {
    if [ "${KOPT_nocolor:-false}" == "true" ]; then
        printf "* $1\n"
    else 
        printf "${WARN_COL}*${NO_COL} WARN: $1\n"
    fi
}

fatal() {
    if [ "${KOPT_nocolor:-false}" == "true" ]; then
        printf "* $1\n"
    else 
        printf "${FATAL_COL}*${NO_COL} FATAL: $1\n"
    fi
    exit 1
}

# Start Docker
start_docker() {
    docker daemon -g $DOCKER_ROOT &
}

# Stop docker
stop_docker() {
    pkill -f docker
    sleep 3
#    ifconfig | grep ^docker0 && ifconfig docker0 down
}

# Apply Docker image to disk
# Exclude "grubenv" symlink since we use FAT32 for UEFI /boot compatability, which does not support symlinks
apply_docker_image() {
    local image=$1 registry=$2 container

    if [ -f /etc/alpine-release ]; then
        sysctl -w kernel.grsecurity.chroot_deny_chmod=0
    fi

    docker run -i --entrypoint /bin/true $registry/$image
    container=$(docker ps -a -l | awk '/true/ {print $1}')

    docker export ${container} | tar -x -h -C $ROOT \
        --exclude=boot/grub/grubenv \
        --exclude=boot/grub2/grubenv \
        --exclude=sys/.keep
}

# Get disk size in MB
disk_size_mb() {
    local disk=$1

    parted --script $disk unit MB print | grep "^Disk $disk" | awk '{print $NF}'
}

# Wait for disks to become available
wait_for_disk() {
    local disk=$1

    while [ ! -b $disk ]; do
        sleep 1
        echo -n .
    done
}

# Wait for network to become available
wait_for_network() {
    local gw=$(route -n | awk '/UG/ { print $2 }')

    counter=0
    while ! ping -w 1 -c 1 $gw &>/dev/null; do
        sleep 1s
        echo -n .
        counter=$((counter+1))
        if [[ "$counter" -gt 100 ]]; then
            fatal "Network failed to come up after 100 seconds"
        fi
    done
    echo
}

# Zero out partition table completely
clear_disk_pt() {
    local disk=$1

    dd if=/dev/zero of=$disk bs=512 count=1 conv=notrunc
}

# Wipe LVM
wipe_lvm() {
    set +e
    udevadm trigger
    udevadm settle
    vgscan
    lvscan

    for VG in $(vgs -o name | tail -n +2); do
        vgremove --force ${VG}
    done
    for PV in $(pvs -o name | tail -n +2); do
        pvremove --force --force ${PV}
    done
    sleep 1s
    set -e
}

# Wipe MD Raid
wipe_mdraid() {
    local disk1=$1 disk2=$2

    set +e
    for MD in $(cd /dev; ls -d md? 2>/dev/null); do
        mdadm --stop ${MD}
    done

    udevadm control --reload
    sleep 1s
    set -e
}

# Partition disk using GPT
partition_disk_gpt() {
    local disk=$1

    # GUID Partition Table (GPT)
    sgdisk -Z $disk
    sgdisk -og $disk

    # Legacy BIOS boot partition is always EF02
    sgdisk -n 1:2048:+1M -t 1:ef02 $disk

    # 2nd (/boot) partition is always EF00
    sgdisk -n 2::+500M -t 2:ef00 $disk

    # LVM partition
    sgdisk -n 3 -t 3:8300 $disk

    # IMPORTANT: Ensure bios that can't handle GPT directly can still boot (e.g. Dell Desktops)
    parted --script --align optimal $disk disk_toggle pmbr_boot
}

# Partition disk using MBR
partition_disk_mbr() {
    local disk=$1

    # MBR Partition Table
    parted --script --align optimal $disk mktable msdos

    # 1st (placehoder) is always oddball (0="empty") type so we don't use it
    # this corresponds to the "Legacy BIOS" GPT partition, and is created so
    # we use the same partitioning scheme regardless of partition table type
    parted --script --align optimal $disk mkpart primary ext2 1 2
    sfdisk --part-type $disk 1 df

    # 2nd (/boot) partition is always EFI type, in case we want to boot UEFI
    parted --script --align optimal $disk mkpart primary 2 502
    parted --script $disk set 2 boot on
    sfdisk --part-type $disk 2 ef

    # LVM partition
    parted --script --align optimal $disk mkpart primary 502 $(disk_size_mb $disk)
}

# Create base layout for software RAID
create_mdraid() {
    local disk1=$1 disk2=$2
    local md0="/dev/md0" md1="/dev/md1"
    local devroot=${md1}

    # Set RAID flag
    parted --script $disk1 set 2 raid on
    parted --script $disk1 set 3 raid on
    parted --script $disk2 set 2 raid on
    parted --script $disk2 set 3 raid on

    # Create RAID
    mdadm -Ss
    yes | mdadm --create ${md0} --level=1 --raid-devices=2 ${disk1}2 ${disk2}2
    yes | mdadm --create ${md1} --level=1 --raid-devices=2 ${disk1}3 ${disk2}3

    # FAT filesystem label can only contain uppercase chars
    mkfs.vfat -F32 -n BOOTFS ${md0}
    sleep 0.2
    partprobe ${disk1} ${disk2}

    # Create the root VG
    pvcreate --force --force --yes ${devroot}
    vgcreate vg_root ${devroot}

    DEV_BOOT=${md0}
}

create_lvm_vgs() {
    local disk=$1 devroot=${1}3

    mkfs.vfat -F32 -n BOOTFS ${disk}2
    sleep 0.2
    partprobe ${disk}

    pvcreate --force --force --yes ${devroot}
    vgcreate vg_root ${devroot}

    DEV_BOOT="${disk}2"
}

# Create Logical Volumes
create_lvm_lvs() {
    lvcreate -y -n lv_root -L 10G vg_root
    lvcreate -y -n lv_swap -L 4G vg_root
    lvcreate -y -n lv_var -L 15G vg_root
    lvcreate -y -n lv_docker -l +100%FREE vg_root
}

# Create filesystems
create_lvm_fss() {
    mkfs.ext4 -i 4096 -q -L "rootfs" /dev/vg_root/lv_root
    mkfs.ext4 -i 4096 -q -L "varfs" /dev/vg_root/lv_var
    mkswap -L swapfs /dev/vg_root/lv_swap
    mkfs.ext4 -i 4096 -q -L "docker"  /dev/vg_root/lv_docker
}

# Mount filesystmes
mount_fs() {
    mkdir -p $ROOT
    mount -t ext4 /dev/vg_root/lv_root $ROOT

    mkdir -p $ROOT/boot
    mount -t vfat ${DEV_BOOT} $ROOT/boot

    mkdir -p $ROOT/var
    mount -t ext4 /dev/vg_root/lv_var $ROOT/var

    mkdir -p $DOCKER_ROOT
    mount -t ext4 /dev/vg_root/lv_docker $DOCKER_ROOT

    mkdir -p $ROOT/{dev,proc,sys}
    mount -o bind /dev $ROOT/dev
    mount -o bind /proc $ROOT/proc
    mount -o bind /sys $ROOT/sys
}

umount_fs() {
    umount $ROOT/dev
    umount $ROOT/proc
    umount $ROOT/sys
    umount $ROOT/boot
    umount $ROOT/var
    umount $ROOT
    umount $DOCKER_ROOT
    sync
}

add_sshkey() {
    if [ "${KOPT_sshkey:-none}" == "none" ]; then
        info "No SSH Key specified"
        return
    fi

    mkdir -p $ROOT/home/dock2box/.ssh
    chmod 700 $ROOT/home/dock2box $ROOT/home/dock2box/.ssh
    echo "ssh-rsa $KOPT_sshkey sshkey@kopt" >>$ROOT/home/dock2box/.ssh/authorized_keys
    chroot $ROOT chown -R dock2box:dock2box /home/dock2box
}

release_dhcp() {
#    killall -SIGUSR2 udhcpc
    echo
}

get_sda_device() {
    sdadev=$(ls /dev/vda)
    if [[ -z "${sdadev}+abc" ]] || ( [[ -z "${sdadev}" ]] && [[ "${sdadev+abc}" == "abc" ]] ); then
        sdadev='/dev/sda'
    fi
    echo ${sdadev}
}