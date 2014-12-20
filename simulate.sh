#!/bin/bash
#
#------------------------------------------------------------------------------
#
# Starts the qemu emulator with the compiled buildroot for testing new netcamel
# configurations.
#
#------------------------------------------------------------------------------

BUILDROOT=./buildroot
QEMU=qemu-system-mips
QEMU_OPTIONS=-nographic
KERNEL=${BUILDROOT}/output/images/vmlinux
ROOTFS=${BUILDROOT}/output/images/rootfs.ext2
LINUX_ARGS="root=/dev/hda console=ttyS0"

${QEMU} ${QEMU_OPTIONS} \
	-kernel ${KERNEL} \
	-drive file=${ROOTFS} \
	-append "${LINUX_ARGS}"

#qemu-system-mips -nographic -kernel output/images/vmlinux -drive file=output/images/rootfs.ext2 -append "root=/dev/hda console=ttyS0" -netdev user,id=fred -device pcnet,netdev=fred
