#!/usr/bin/env bash
# Serve the completed builder artifact only inside the demo namespace.
set -euo pipefail
NAMESPACE=${NAMESPACE:-rocket-ramen}
PRIVATE_DIR=${PRIVATE_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/rocket-ramen-demo"}
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" ]] || SSH_KEY="$PRIVATE_DIR/automation-key"
: "${BUILDER_DISK_DIR:?Set BUILDER_DISK_DIR to the builder directory containing disk.qcow2}"
[[ "$BUILDER_DISK_DIR" =~ ^/var/lib/rocket-ramen-builder/[a-zA-Z0-9_./-]+$ && "$BUILDER_DISK_DIR" != *..* ]] || { echo 'Invalid builder artifact directory.' >&2; exit 1; }
port=${BUILDER_SSH_PORT:-2228}
[[ "$port" =~ ^[0-9]+$ ]] || exit 2
ssh -p "$port" -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$PRIVATE_DIR/builder-known_hosts" -o HostKeyAlias=orders-builder demo-automation@127.0.0.1 \
  "sudo test -s '$BUILDER_DISK_DIR/disk.qcow2' && sudo qemu-img check '$BUILDER_DISK_DIR/disk.qcow2' && sudo systemd-run --unit=orders-bootc-artifacts --property=Restart=no /usr/bin/python3 -m http.server 8081 --directory '$BUILDER_DISK_DIR'"
cat <<'YAML' | oc -n "$NAMESPACE" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: orders-bootc-artifacts
spec:
  selector: {vm.kubevirt.io/name: orders-builder}
  ports:
    - {name: http, port: 8081, targetPort: 8081}
YAML
printf 'Disk URL: http://orders-bootc-artifacts.%s.svc:8081/disk.qcow2\n' "$NAMESPACE"
