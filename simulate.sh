#!/bin/bash
#
#------------------------------------------------------------------------------
#
# Starts the qemu emulator with the compiled buildroot for testing new netcamel
# configurations.
#
#------------------------------------------------------------------------------

BUILDROOT=./buildroot
QEMU=./qemu-system-mips
QEMU_OPTIONS=-nographic
KERNEL=${BUILDROOT}/output/images/vmlinux
ROOTFS=${BUILDROOT}/output/images/rootfs.ext2
LINUX_ARGS="root=/dev/hda console=ttyS0"
BASE_NET="-netdev user,id=main,host=10.1.0.1,net=10.1.0.0/24,dhcpstart=10.1.0.16 -device pcnet,netdev=main"
EXTRA_NET="-device pcnet"
FS="-fsdev local,id=joe,security_model=none,path=/tmp -device virtio-9p-pci,fsdev=joe,mount_tag=joetag"


${QEMU} ${QEMU_OPTIONS} \
	-kernel ${KERNEL} \
	-drive file=${ROOTFS} \
	-append "${LINUX_ARGS}" \
	${BASE_NET} \
	${EXTRA_NET} \
	${FS}

#qemu-system-mips -nographic -kernel output/images/vmlinux -drive file=output/images/rootfs.ext2 -append "root=/dev/hda console=ttyS0" -netdev user,id=fred -device pcnet,netdev=fred
