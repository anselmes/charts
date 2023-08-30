#!/bin/sh

set -ex

COMMAND="${*:-start}"

kernel_modules () {
  chroot /mnt/host-rootfs modprobe dummy
}

test_vip () {
  ip addr show ${interface} | \
    awk "/inet / && /${interface}/{print \$2 }" | \
    awk -F '/' '{ print $1 }' | \
    grep -q "${addr%/*}"
}

start () {
  kernel_modules
  ip link show ${interface} > /dev/null || ip link add ${interface} type dummy
  if ! test_vip; then
   ip addr add ${addr} dev ${interface}
  fi
  ip link set ${interface} up
}

sleep () {
  exec /bin/sh -c "while :; do sleep 2073600; done"
}

stop () {
  ip link show ${interface} > /dev/null || exit 0
  if test_vip; then
   ip addr del ${addr} dev ${interface}
  fi
  if [ "$(ip address show ${interface} | \
          awk "/inet / && /${interface}/{print \$2 }" | \
          wc -l)" -le "0" ]; then
    ip link set ${interface} down
    ip link del ${interface}
  fi
}

$COMMAND
