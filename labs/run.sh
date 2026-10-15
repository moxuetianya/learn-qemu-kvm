#!/bin/bash

TOPDIR=$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)
( 
cd $TOPDIR
qemu-system-x86_64 -name alpine -machine accel=kvm,type=q35 -cpu host -smp 2 -m 1G -drive file=labs/images/alpine.qcow2,format=qcow2,if=virtio -drive file=labs/images/alpine-virt-3.20.3-x86_64.iso,media=cdrom,readonly=on -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -vnc :0
)

# vncview 192.168.5.99:5900
# remote-viewer vnc://127.0.0.1:5900
