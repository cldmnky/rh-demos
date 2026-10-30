#!/usr/bin/env bash
set -euo pipefail
: "${NAMESPACE:?Set NAMESPACE to the demo namespace}"
RHEL_IMAGE=${RHEL_IMAGE:-docker://registry.redhat.io/rhel10/rhel-guest-image:10.2}
RHEL_IMPORT_SECRET=${RHEL_IMPORT_SECRET:-rhel-registry-auth}
RHEL_DATA_VOLUME=${RHEL_DATA_VOLUME:-rhel10-golden}
RHEL_DATA_SOURCE=${RHEL_DATA_SOURCE:-rhel10-demo}
RHEL_DISK_SIZE=${RHEL_DISK_SIZE:-20Gi}
export NAMESPACE RHEL_IMAGE RHEL_IMPORT_SECRET RHEL_DATA_VOLUME RHEL_DATA_SOURCE RHEL_DISK_SIZE
oc -n "$NAMESPACE" get secret "$RHEL_IMPORT_SECRET" >/dev/null
ruby -rjson -e '
  ns=ENV.fetch("NAMESPACE"); dv=ENV.fetch("RHEL_DATA_VOLUME")
  items=[{apiVersion:"cdi.kubevirt.io/v1beta1",kind:"DataVolume",metadata:{name:dv,namespace:ns,annotations:{"cdi.kubevirt.io/storage.bind.immediate.requested"=>"true"}},spec:{source:{registry:{url:ENV.fetch("RHEL_IMAGE"),secretRef:ENV.fetch("RHEL_IMPORT_SECRET")}},storage:{resources:{requests:{storage:ENV.fetch("RHEL_DISK_SIZE")}}}}},{apiVersion:"cdi.kubevirt.io/v1beta1",kind:"DataSource",metadata:{name:ENV.fetch("RHEL_DATA_SOURCE"),namespace:ns},spec:{source:{pvc:{name:dv,namespace:ns}}}}]
  puts JSON.generate({apiVersion:"v1",kind:"List",items:items})
' | oc -n "$NAMESPACE" apply -f -
oc -n "$NAMESPACE" wait --for=condition=Ready "datasource/$RHEL_DATA_SOURCE" --timeout=20m
