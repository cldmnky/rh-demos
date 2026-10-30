#!/usr/bin/env bash
# Attach only the restored copy of the MariaDB disk to the isolated target VM.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
TARGET_PVC=${TARGET_PVC:-orders-db-bootc-data}
[[ "$TARGET_PVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "$TARGET_PVC" != orders-db-data ]] || { echo 'Refusing invalid or original database PVC.' >&2; exit 1; }
source=$(oc -n "$NAMESPACE" get pvc "$TARGET_PVC" -o jsonpath='{.spec.dataSource.kind}')
[[ "$source" == VolumeSnapshot ]] || { echo 'Target PVC must be restored from a snapshot.' >&2; exit 1; }
strategy=$(oc -n "$NAMESPACE" get vm orders-db-bootc -o jsonpath='{.spec.runStrategy}')
if [[ "$strategy" != Halted ]]; then virtctl stop -n "$NAMESPACE" orders-db-bootc; fi
for ((i=0; i<120; i++)); do
  [[ -z $(oc -n "$NAMESPACE" get vmi orders-db-bootc --ignore-not-found -o name) ]] && break
  [[ $i -lt 119 ]] || { echo 'Timed out stopping target VM.' >&2; exit 1; }
  sleep 5
done
export TARGET_PVC
patch=$(oc -n "$NAMESPACE" get vm orders-db-bootc -o json | ruby -rjson -e '
  j=JSON.parse(STDIN.read); spec=j.fetch("spec").fetch("template").fetch("spec"); vols=spec.fetch("volumes"); disks=spec.fetch("domain").fetch("devices").fetch("disks")
  vi=vols.index{|x| x["name"]=="datadisk"}; di=disks.index{|x|x["name"]=="datadisk"}
  abort "Inconsistent existing target disk definition" if vi.nil? != di.nil?
  volume={name:"datadisk",persistentVolumeClaim:{claimName:ENV.fetch("TARGET_PVC")}}
  patches=if vi
    [{op:"replace",path:"/spec/template/spec/volumes/#{vi}",value:volume}]
  else
    [{op:"add",path:"/spec/template/spec/domain/devices/disks/-",value:{name:"datadisk",serial:"orders-data",disk:{bus:"virtio"}}},{op:"add",path:"/spec/template/spec/volumes/-",value:volume}]
  end
  puts JSON.generate(patches)
')
oc -n "$NAMESPACE" patch vm orders-db-bootc --type=json -p "$patch"
virtctl start -n "$NAMESPACE" orders-db-bootc
oc -n "$NAMESPACE" wait --for=condition=Ready vm/orders-db-bootc --timeout=15m
