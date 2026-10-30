#!/usr/bin/env bash
# Run as root on the isolated target VM, after attaching the cloned data disk.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root inside the target VM.' >&2; exit 1; }
disk=/dev/disk/by-id/virtio-orders-data
[[ -b "$disk" ]] || { echo 'The cloned orders-data disk is missing.' >&2; exit 1; }
[[ $(blkid -p -o value -s TYPE "$disk") == xfs ]] || { echo 'Expected an existing XFS database disk; refusing to format or mount.' >&2; exit 1; }
systemctl stop mariadb.service || true
mkdir -p /var/lib/mysql
if ! mountpoint -q /var/lib/mysql; then
  [[ -z $(find /var/lib/mysql -mindepth 1 -maxdepth 1 -print -quit) ]] || { echo 'The original MariaDB directory is not empty; refusing to hide it.' >&2; exit 1; }
  mount -t xfs "$disk" /var/lib/mysql
fi
mounted=$(findmnt -rn -o MAJ:MIN --target /var/lib/mysql)
disk_id=$(lsblk -dnro MAJ:MIN "$disk")
[[ "$mounted" == "$disk_id" ]] || { echo 'A different filesystem is mounted on /var/lib/mysql.' >&2; exit 1; }
[[ -d /var/lib/mysql/mysql && -d /var/lib/mysql/orders ]] || { echo 'Expected database directories are missing; refusing to initialize.' >&2; exit 1; }
if ! grep -q '^/dev/disk/by-id/virtio-orders-data[[:space:]]\+/var/lib/mysql[[:space:]]' /etc/fstab; then
  printf '%s\n' '/dev/disk/by-id/virtio-orders-data /var/lib/mysql xfs defaults 0 2' >> /etc/fstab
fi
chown mysql:mysql /var/lib/mysql
restorecon -RF /var/lib/mysql
install -d -m 755 /etc/my.cnf.d
printf '[mysqld]\nbind-address=0.0.0.0\n' > /etc/my.cnf.d/orders-network.cnf
install -d -m 755 /etc/systemd/system/mariadb.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/mysql\n' > /etc/systemd/system/mariadb.service.d/orders-data.conf
systemctl daemon-reload
systemctl enable --now mariadb.service
mariadb -Nse 'SELECT COUNT(*) FROM orders.menu_items' | awk '$1 > 0 {ok=1} END {exit !ok}'
printf 'Cloned database mounted and MariaDB menu verified.\n'
