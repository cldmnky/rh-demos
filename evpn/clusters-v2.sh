#!/usr/bin/env bash
# evpn/clusters-v2.sh
#
# Manage two kind clusters running OVN-Kubernetes with EVPN enabled,
# using podman as the OCI runtime. Sets up a stretched Layer-2
# ClusterUserDefinedNetwork across both clusters via BGP EVPN,
# with two FRR provider-edge containers acting as route reflectors.
#
# v2: Separate podman bridge networks per site + eBGP transit.
#
# Network topology:
#   evpn-site1   (10.100.0.0/24)  — Cluster 1 nodes + edge1  (iBGP AS 65001)
#   evpn-site2   (10.200.0.0/24)  — Cluster 2 nodes + edge2  (iBGP AS 65002)
#   evpn-transit (10.250.0.0/24)  — edge1 <-> edge2          (eBGP 65001↔65002)
#   kind         (shared)         — management / API server / image pull
#
# Subcommands:
#   create   - Create the 2 kind clusters, install OVN-K + EVPN + frr-k8s,
#              deploy provider edge FRR containers, wire up VTEP/CUDN/RA
#   destroy  - Delete the 2 clusters and tear down provider edge + networks
#   start    - Start previously stopped kind nodes and provider edge
#   stop     - Stop kind nodes and provider edge (preserves data + configs)
#   status   - Show cluster, network, BGP, and EVPN state
#   help     - Show this help
#
# Layout produced:
#   evpn/
#   ├── clusters-v2.sh
#   ├── kubeconfig.cluster1
#   ├── kubeconfig.cluster2
#   ├── edge1_frr.conf
#   ├── edge1_daemons
#   ├── edge2_frr.conf
#   ├── edge2_daemons
#   └── edge_vtysh.conf
#
# Notes:
# - Each cluster's nodes live on their own podman bridge network (site1/site2).
#   The shared "kind" network is kept for management (API server, image pull).
# - Two FRR containers (evpn-edge1, evpn-edge2) are dual-homed: site + transit.
#   Each peers iBGP with its cluster's nodes and eBGP with the remote edge.
# - The OVN-Kubernetes repo is cloned once (default: $HOME/.cache/evpn/ovn-kubernetes)
#   so we can install the official helm chart. Override OVN_K_REPO_URL / OVN_K_REF
#   to pin to a specific branch, tag, or fork.
# - Prebuilt OVN-K image is used by default; override OVN_K_IMAGE to pin a tag.
# - A Layer-2 stretched CUDN (default VNI 110, subnet 192.170.1.0/24) is
#   created across both clusters using EVPN transport.

set -euo pipefail

# ---------- Configuration (override via env) ----------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}")

# OVN-K source / chart
OVN_K_REPO_URL="${OVN_K_REPO_URL:-https://github.com/ovn-kubernetes/ovn-kubernetes.git}"
OVN_K_REF="${OVN_K_REF:-master}"
OVN_K_CACHE_DIR="${OVN_K_CACHE_DIR:-$HOME/.cache/evpn/ovn-kubernetes}"
OVN_K_IMAGE="${OVN_K_IMAGE:-ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-fedora:master}"
OVN_K_IMAGE_PULL_TIMEOUT="${OVN_K_IMAGE_PULL_TIMEOUT:-10m}"

# Kind / podman
KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
export KIND_EXPERIMENTAL_PROVIDER
KIND_NETWORK="${KIND_NETWORK:-kind}"
# kindest/node image: pin to a K8s version compatible with kind v0.27+
KIND_IMAGE="${KIND_IMAGE:-docker.io/kindest/node}"
K8S_VERSION="${K8S_VERSION:-v1.32.0}"

# Cluster topology
NAME_PREFIX="${NAME_PREFIX:-evpn-cluster}"
NUM_WORKERS="${NUM_WORKERS:-1}"
MTU="${MTU:-1400}"

# Per-cluster addressing
CLUSTER1_NAME="${NAME_PREFIX}1"
CLUSTER2_NAME="${NAME_PREFIX}2"
CLUSTER1_POD_CIDR="${CLUSTER1_POD_CIDR:-10.244.0.0/16}"
CLUSTER1_SVC_CIDR="${CLUSTER1_SVC_CIDR:-10.96.0.0/16}"
CLUSTER2_POD_CIDR="${CLUSTER2_POD_CIDR:-10.245.0.0/16}"
CLUSTER2_SVC_CIDR="${CLUSTER2_SVC_CIDR:-10.97.0.0/16}"

# ---------- Site / transit networks (v2) ----------

SITE1_NETWORK="${SITE1_NETWORK:-evpn-site1}"
SITE1_SUBNET="${SITE1_SUBNET:-10.100.0.0/24}"
SITE2_NETWORK="${SITE2_NETWORK:-evpn-site2}"
SITE2_SUBNET="${SITE2_SUBNET:-10.200.0.0/24}"
TRANSIT_NETWORK="${TRANSIT_NETWORK:-evpn-transit}"
TRANSIT_SUBNET="${TRANSIT_SUBNET:-10.250.0.0/24}"

SITE1_AS="${SITE1_AS:-65001}"
SITE2_AS="${SITE2_AS:-65002}"

# Provider edge containers (podman)
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.1.0}"
EDGE1_CONTAINER="${EDGE1_CONTAINER:-evpn-edge1}"
EDGE2_CONTAINER="${EDGE2_CONTAINER:-evpn-edge2}"

# Edge IPs — site + transit
EDGE1_SITE_IP="${EDGE1_SITE_IP:-10.100.0.100}"
EDGE2_SITE_IP="${EDGE2_SITE_IP:-10.200.0.100}"
EDGE1_TRANSIT_IP="${EDGE1_TRANSIT_IP:-10.250.0.1}"
EDGE2_TRANSIT_IP="${EDGE2_TRANSIT_IP:-10.250.0.2}"

# BGP / EVPN
# Pinned to a tag (v0.0.21) of the frr-k8s all-in-one manifest that is known
# to work with OVN-K EVPN. Override if you need a different version.
FRR_K8S_MANIFEST_URL="${FRR_K8S_MANIFEST_URL:-https://raw.githubusercontent.com/metallb/frr-k8s/v0.0.21/config/all-in-one/frr-k8s.yaml}"
FRR_K8S_NAMESPACE="${FRR_K8S_NAMESPACE:-frr-k8s-system}"

# EVPN stretched L2 network
EVPN_NAMESPACE="${EVPN_NAMESPACE:-vm-workloads}"
CUDN_NAME="${CUDN_NAME:-stretched-l2}"
CUDN_VNI="${CUDN_VNI:-110}"
CUDN_SUBNETS="${CUDN_SUBNETS:-192.170.1.0/24}"
VTEP_CIDRS="${VTEP_CIDRS:-10.100.0.0/16,10.200.0.0/16}"
ROUTE_TARGET="${ROUTE_TARGET:-64512:${CUDN_VNI}}"

# Paths (under evpn/)
KUBECONFIG_C1="${SCRIPT_DIR}/kubeconfig.${CLUSTER1_NAME}"
KUBECONFIG_C2="${SCRIPT_DIR}/kubeconfig.${CLUSTER2_NAME}"
KIND_CONFIG_C1="${SCRIPT_DIR}/kind-${CLUSTER1_NAME}.yaml"
KIND_CONFIG_C2="${SCRIPT_DIR}/kind-${CLUSTER2_NAME}.yaml"
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------- Logging helpers ----------

_log()   { printf '\033[1;34m[evpn]\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33m[evpn]\033[0m %s\n' "$*" >&2; }
_err()   { printf '\033[1;31m[evpn]\033[0m %s\n' "$*" >&2; }
_die()   { _err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

require() {
  command_exists "$1" || _die "Missing required command: $1"
}

# ---------- Preflight ----------

check_deps() {
  local full="${1:-full}"
  _log "Checking dependencies..."
  require kind
  require podman
  if [[ "${full}" == "full" ]]; then
    require helm
    require kubectl
    require git
    case "$(uname -s)" in
      Linux)
        if [[ $EUID -ne 0 ]] && [[ "${KIND_EXPERIMENTAL_PROVIDER}" == "podman" ]]; then
          _warn "On Linux, OVN-K recommends running kind as root when using podman."
          _warn "Continuing as $(id -un); set ROOTLESS_OK=1 to suppress this check."
          [[ "${ROOTLESS_OK:-0}" == "1" ]] || _die "Set ROOTLESS_OK=1 to proceed as non-root, or re-run with sudo."
        fi
        ;;
    esac
  fi
  podman network ls --format '{{.Name}}' >/dev/null 2>&1 \
    || _die "podman cannot list networks - is the podman machine running? (try: podman machine start)"
}

# Pre-load kernel modules in the podman machine that kind containers need
# but cannot load themselves (notably openvswitch for OVN-K).
ensure_kernel_modules() {
  local module
  for module in openvswitch; do
    if ! podman machine ssh "lsmod | grep -q '^${module}'" 2>/dev/null; then
      _log "Loading kernel module '${module}' in podman machine..."
      podman machine ssh "sudo modprobe ${module}" 2>&1 | sed 's/^/  /' || _warn "Could not load ${module}"
    fi
  done
}

# Install external CRDs that OVN-K depends on (NAD, IPAMClaims, MultiNetworkPolicy).
install_ovn_k_dep_crds() {
  local kubeconfig="$1" label="$2"
  _log "Installing external CRDs for ${label}..."

  # NetworkAttachmentDefinition (from Multus project, CRD only)
  cat <<'EOF' | KUBECONFIG="${kubeconfig}" kubectl apply -f - >/dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: network-attachment-definitions.k8s.cni.cncf.io
spec:
  group: k8s.cni.cncf.io
  names:
    kind: NetworkAttachmentDefinition
    listKind: NetworkAttachmentDefinitionList
    plural: network-attachment-definitions
    singular: network-attachment-definition
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF

  # IPAMClaim
  local claims_url="https://raw.githubusercontent.com/k8snetworkplumbingwg/ipamclaims/v0.5.1-alpha/artifacts/k8s.cni.cncf.io_ipamclaims.yaml"
  KUBECONFIG="${kubeconfig}" kubectl apply -f "${claims_url}" >/dev/null 2>&1 || _warn "Could not install IPAMClaim CRD"

  # MultiNetworkPolicy
  local mnp_url="https://raw.githubusercontent.com/k8snetworkplumbingwg/multi-networkpolicy/refs/tags/v1.0.1/scheme.yml"
  KUBECONFIG="${kubeconfig}" kubectl apply -f "${mnp_url}" >/dev/null 2>&1 || _warn "Could not install MultiNetworkPolicy CRD"
}

# ---------- Podman networks ----------

ensure_kind_network() {
  if ! podman network ls --format '{{.Name}}' | grep -qx "${KIND_NETWORK}"; then
    _log "Creating podman network '${KIND_NETWORK}'..."
    podman network create --driver bridge "${KIND_NETWORK}" >/dev/null
  else
    _log "Podman network '${KIND_NETWORK}' already exists."
  fi
}

ensure_site_networks() {
  local net subnet
  while read -r net subnet; do
    if ! podman network ls --format '{{.Name}}' | grep -qx "${net}"; then
      _log "Creating podman network '${net}' (${subnet})..."
      podman network create --driver bridge --subnet "${subnet}" "${net}" >/dev/null
    else
      _log "Podman network '${net}' already exists."
    fi
  done <<EOF
${SITE1_NETWORK} ${SITE1_SUBNET}
${SITE2_NETWORK} ${SITE2_SUBNET}
${TRANSIT_NETWORK} ${TRANSIT_SUBNET}
EOF
}

maybe_remove_kind_network() {
  if podman network ls --format '{{.Name}}' | grep -qx "${KIND_NETWORK}"; then
    local attached
    attached=$(podman network inspect "${KIND_NETWORK}" --format '{{len .Containers}}' 2>/dev/null || echo 0)
    if [[ "${attached}" == "0" ]]; then
      _log "Removing empty podman network '${KIND_NETWORK}'..."
      podman network rm "${KIND_NETWORK}" >/dev/null 2>&1 || true
    else
      _log "Podman network '${KIND_NETWORK}' still in use by ${attached} container(s); leaving it."
    fi
  fi
}

remove_site_networks() {
  local net
  for net in "${SITE1_NETWORK}" "${SITE2_NETWORK}" "${TRANSIT_NETWORK}"; do
    if podman network ls --format '{{.Name}}' | grep -qx "${net}"; then
      local attached
      attached=$(podman network inspect "${net}" --format '{{len .Containers}}' 2>/dev/null || echo 0)
      if [[ "${attached}" == "0" ]]; then
        _log "Removing podman network '${net}'..."
        podman network rm "${net}" >/dev/null 2>&1 || true
      else
        _log "Podman network '${net}' still in use by ${attached} container(s); leaving it."
      fi
    fi
  done
}

# ---------- OVN-K repo + image ----------

ensure_ovn_k_repo() {
  if [[ -d "${OVN_K_CACHE_DIR}/.git" ]]; then
    _log "Updating cached OVN-K repo at ${OVN_K_CACHE_DIR}..."
    # FETCH_HEAD works for branches, tags, and commit SHAs
    git -C "${OVN_K_CACHE_DIR}" fetch --quiet --depth 1 origin "${OVN_K_REF}" \
      || _die "Failed to fetch OVN-K ref ${OVN_K_REF}"
    git -C "${OVN_K_CACHE_DIR}" reset --hard --quiet FETCH_HEAD \
      || _die "Failed to reset OVN-K to ${OVN_K_REF}"
  else
    _log "Cloning OVN-K (${OVN_K_REF}) into ${OVN_K_CACHE_DIR}..."
    mkdir -p "$(dirname "${OVN_K_CACHE_DIR}")"
    git clone --quiet --depth 1 --branch "${OVN_K_REF}" "${OVN_K_REPO_URL}" "${OVN_K_CACHE_DIR}" \
      || _die "Failed to clone OVN-K repo"
  fi
  [[ -d "${OVN_K_CACHE_DIR}/helm/ovn-kubernetes" ]] \
    || _die "Expected chart at ${OVN_K_CACHE_DIR}/helm/ovn-kubernetes after clone"
  _patch_crds_for_k8s_compat
}

_podman_pull() {
  # `podman pull` has no --timeout flag in current releases; wrap with external
  # `timeout` so a hung registry doesn't block the whole run.
  local img="$1" how_long="${OVN_K_IMAGE_PULL_TIMEOUT}"
  timeout "${how_long}" podman pull --quiet "${img}"
}

ensure_ovn_k_image() {
  local img="${OVN_K_IMAGE}"
  if podman image exists "${img}"; then
    _log "OVN-K image already present locally: ${img}"
    return 0
  fi
  _log "Pulling OVN-K image ${img} (timeout: ${OVN_K_IMAGE_PULL_TIMEOUT})..."
  _podman_pull "${img}" \
    || _die "Failed to pull OVN-K image ${img}. Override OVN_K_IMAGE to a tag you can reach (e.g. release-1.3)."
  podman image exists "${img}" || _die "Image ${img} not present after pull"
}

# ---------- Kind config generation ----------

_kind_node_block() {
  local role="$1"
  if [[ "${role}" == "control-plane" ]]; then
    cat <<'YAML'
 - role: control-plane
   kubeadmConfigPatches:
   - |
     kind: InitConfiguration
     nodeRegistration:
       kubeletExtraArgs:
         node-labels: "ingress-ready=true"
         authorization-mode: "AlwaysAllow"
YAML
  else
    printf ' - role: worker\n'
  fi
}

render_kind_config() {
  local name="$1" pod_cidr="$2" svc_cidr="$3" out="$4"
  {
    cat <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${name}
networking:
  kubeProxyMode: "none"
  disableDefaultCNI: true
  podSubnet: "${pod_cidr}"
  serviceSubnet: "${svc_cidr}"
nodes:
YAML
    _kind_node_block control-plane
    for _ in $(seq 1 "${NUM_WORKERS}"); do
      _kind_node_block worker
    done
  } > "${out}"
  _log "Wrote kind config: ${out}"
}

# ---------- Cluster lifecycle ----------

_kind_create() {
  local name="$1" cfg="$2" kubeconfig="$3"
  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    _die "Kind cluster '${name}' already exists. Run 'destroy' first, or use a different NAME_PREFIX."
  fi
  local image_ref="${KIND_IMAGE}:${K8S_VERSION}"
  _log "Creating kind cluster '${name}' (image=${image_ref})..."
  kind create cluster \
    --name "${name}" \
    --config "${cfg}" \
    --kubeconfig "${kubeconfig}" \
    --image "${image_ref}" \
    --retain
}

_kind_delete() {
  local name="$1"
  if kind get clusters 2>/dev/null | grep -qx "${name}"; then
    _log "Deleting kind cluster '${name}'..."
    kind delete cluster --name "${name}"
  else
    _log "Kind cluster '${name}' not present; skipping."
  fi
}

_kind_nodes() {
  local name="$1"
  podman ps -a --filter "label=io.x-k8s.kind.cluster=${name}" \
    --format '{{.Names}}' 2>/dev/null | sort
}

_cluster_is_running() {
  local name="$1"
  local n
  n=$(_kind_nodes "${name}" | wc -l | tr -d ' ')
  [[ "${n}" -gt 0 ]] || return 1
  local all_running=0
  local node
  for node in $(_kind_nodes "${name}"); do
    local state
    state=$(podman inspect --format '{{.State.Running}}' "${node}" 2>/dev/null || echo "false")
    [[ "${state}" == "true" ]] || all_running=1
  done
  return "${all_running}"
}

_kind_stop() {
  local name="$1"
  local node
  for node in $(_kind_nodes "${name}"); do
    if podman inspect --format '{{.State.Running}}' "${node}" 2>/dev/null | grep -q true; then
      _log "  stop ${node}"
      podman stop "${node}" >/dev/null
    fi
  done
}

_kind_start() {
  local name="$1"
  local node
  for node in $(_kind_nodes "${name}"); do
    if ! podman inspect --format '{{.State.Running}}' "${node}" 2>/dev/null | grep -q true; then
      _log "  start ${node}"
      podman start "${node}" >/dev/null
    fi
  done
}

# Connect all nodes of a cluster to a site network (dual-homed: kind + site).
connect_nodes_to_site_network() {
  local cluster_name="$1" site_network="$2"
  _log "Connecting ${cluster_name} nodes to ${site_network}..."
  local n
  for n in $(_kind_nodes "${cluster_name}"); do
    podman network connect "${site_network}" "${n}" >/dev/null
    _log "  Connected ${n} to ${site_network}"
  done
}

# Strip CEL validation rules from OVN-K CRDs that require k8s 1.32+
# feature gates (CELVariableScoping). These rules are data-plane validation
# only — stripping them is harmless.
_patch_crds_for_k8s_compat() {
  local script="${SCRIPT_DIR}/.fix_crds.rb" crd_dir="${OVN_K_CACHE_DIR}/helm/ovn-kubernetes/crds"
  cat > "${script}" <<-'RUBY'
require "yaml"
dir = ARGV.first or abort "Usage: #{$0} <crd-dir>"
Dir["#{dir}/*.yaml"].each do |path|
  data = YAML.safe_load(File.read(path), permitted_classes: [Symbol])
  next unless data.is_a?(Hash) && data["spec"]
  specs = data["spec"]
  versions = specs["versions"] || [specs]
  versions.each do |v|
    schema = v.dig("schema", "openAPIV3Schema") || v
    walk = lambda do |obj|
      case obj
      when Hash
        if obj["x-kubernetes-validations"]
          obj["x-kubernetes-validations"] = obj["x-kubernetes-validations"].select do |rule|
            # strip self.all with 3+ args (map/keyed comprehension form)
            r = rule["rule"].to_s
            # strip any .all(k, v, ...) with 3+ args (keyed comprehension form)
            !(r.include?(".all(") && r.count(",") >= 2)
          end
          obj.delete("x-kubernetes-validations") if obj["x-kubernetes-validations"].empty?
        end
        obj.each_value { |v| walk.call(v) }
      when Array
        obj.each { |v| walk.call(v) }
      end
    end
    walk.call(schema)
  end
  File.write(path, YAML.dump(data))
end
RUBY
  ruby "${script}" "${crd_dir}" && rm -f "${script}"
}

# ---------- OVN-K installation (per cluster) ----------

# Parse an OCI image reference like "registry/path/repo:tag" or
# "registry:5000/path/repo:tag" into repo (no tag) and tag.
# We anchor on the LAST colon before an optional "@digest" suffix and
# require a tag character class so registry ports aren't mistaken for tags.
split_image_ref() {
  local img="$1" repo tag
  if [[ "${img}" == *"@"* ]]; then
    repo="${img%@*}"
    return 0
  fi
  tag="${img##*:}"
  if [[ -z "${tag}" || "${tag}" == *"/"* ]]; then
    # No tag (or colon was a registry port): treat whole thing as repo
    repo="${img}"; tag=""
  else
    repo="${img%:*}"
  fi
  REPO="${repo}"
  TAG="${tag}"
}

# Use kind's internal kubeconfig URL to get the control-plane container's IP.
# This is the same approach the official OVN-K kind.sh uses.
api_server_for() {
  local name="$1" kubeconfig="$2"
  KUBECONFIG="${kubeconfig}" kind get kubeconfig --internal --name "${name}" \
    | sed -n 's/^[[:space:]]*server:[[:space:]]*https*:\/\/\([^:]*\):.*/\1/p' \
    | head -n1
}

# Label every node with its zone name (required by values-single-node-zone.yaml).
label_nodes_for_single_node_zone() {
  local kubeconfig="$1" name="$2"
  local n
  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    KUBECONFIG="${kubeconfig}" kubectl label --overwrite node "${n}" \
      "k8s.ovn.org/zone-name=${n}" >/dev/null
  done < <(KUBECONFIG="${kubeconfig}" kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  _log "  applied k8s.ovn.org/zone-name labels to nodes in ${name}"
}

install_ovn_k_in_cluster() {
  local name="$1" kubeconfig="$2" pod_cidr="$3" svc_cidr="$4"
  local REPO TAG
  split_image_ref "${OVN_K_IMAGE}"
  local image_repo="${REPO}" image_tag="${TAG}"
  local api
  api=$(api_server_for "${name}" "${kubeconfig}")
  [[ -n "${api}" ]] || _die "Could not determine API server IP for ${name}"

  local img_tmp
  img_tmp=$(mktemp -t ovn-k-image.XXXXXX)
  _log "Loading OVN-K image into kind cluster '${name}'..."
  if ! podman save -o "${img_tmp}" "${OVN_K_IMAGE}" >/dev/null; then
    rm -f "${img_tmp}"
    _die "Failed to save OVN-K image to ${img_tmp}"
  fi
  if ! kind load image-archive "${img_tmp}" --name "${name}"; then
    rm -f "${img_tmp}"
    _die "Failed to load OVN-K image into kind cluster ${name}"
  fi
  rm -f "${img_tmp}"

  install_ovn_k_dep_crds "${kubeconfig}" "${name}"
  _log "Installing frr-k8s into '${name}' (BGP/EVPN sidecar)..."
  install_frr_k8s "${kubeconfig}"

  _log "Installing OVN-K chart into '${name}' (api=${api})..."
  local chart_dir="${OVN_K_CACHE_DIR}/helm/ovn-kubernetes"
  local values_file="${chart_dir}/values-single-node-zone.yaml"
  [[ -f "${values_file}" ]] || _die "Missing values file ${values_file}"

  KUBECONFIG="${kubeconfig}" helm upgrade --install ovn-kubernetes "${chart_dir}" \
    -f "${values_file}" \
    --set k8sAPIServer="https://${api}:6443" \
    --set podNetwork="${pod_cidr}" \
    --set serviceNetwork="${svc_cidr}" \
    --set mtu="${MTU}" \
    --set global.image.repository="${image_repo}" \
    --set global.image.tag="${image_tag}" \
    --set global.enableRouteAdvertisements=true \
    --set global.enableEVPN=true \
    --set global.enableMultiNetwork=true \
    --set global.enableNetworkSegmentation=true \
    --set global.gatewayMode="local" \
    --set global.dummyGatewayBridge=true \
    --set ovs-node.updateStrategy="RollingUpdate" \
    --kubeconfig "${kubeconfig}" \
    --wait --timeout 10m
  _log "OVN-K installed in '${name}'."

  label_nodes_for_single_node_zone "${kubeconfig}" "${name}"

  _log "Waiting for OVN-K pods to be ready in '${name}'..."
  KUBECONFIG="${kubeconfig}" kubectl wait --for=condition=Ready pods \
    -l name=ovnkube-control-plane -n ovn-kubernetes --timeout 5m \
    || _warn "ovnkube-control-plane not Ready in ${name} within 5m"
  KUBECONFIG="${kubeconfig}" kubectl rollout status daemonset/ovs-node -n ovn-kubernetes --timeout 5m \
    || _warn "ovs-node daemonset not Ready in ${name} within 5m"
  KUBECONFIG="${kubeconfig}" kubectl rollout status daemonset/ovnkube-node -n ovn-kubernetes --timeout 5m \
    || _warn "ovnkube-node daemonset not Ready in ${name} within 5m"

  # Now that CNI is up, wait for frr-k8s pods (applied earlier) to become ready.
  _log "Waiting for frr-k8s pods in '${name}'..."
  KUBECONFIG="${kubeconfig}" kubectl wait -n "${FRR_K8S_NAMESPACE}" \
    --for=condition=Available deployment/frr-k8s-statuscleaner --timeout 2m \
    || _warn "frr-k8s-statuscleaner did not become Available in ${name}"
  KUBECONFIG="${kubeconfig}" kubectl rollout status -n "${FRR_K8S_NAMESPACE}" \
    daemonset/frr-k8s-daemon --timeout 2m \
    || _warn "frr-k8s-daemon did not roll out in ${name}"

  fix_cni_version_and_system_pods "${kubeconfig}" "${name}"

  # frr-k8s worker controllers fail to reach the kubernetes ClusterIP
  # (10.96.0.1 / 10.97.0.1) due to OVN-K service proxy not programming
  # the load balancer on workers.  Patch the daemonset so frr-k8s connects
  # directly to the API server on port 6443 instead.
  local cp_node api_ip
  cp_node=$(KUBECONFIG="${kubeconfig}" kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  api_ip=$(KUBECONFIG="${kubeconfig}" kubectl get node "${cp_node}" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "${api}")
  _log "Patching frr-k8s-daemon in '${name}' to use direct API server at ${api_ip}:6443..."
  KUBECONFIG="${kubeconfig}" kubectl patch daemonset -n "${FRR_K8S_NAMESPACE}" frr-k8s-daemon --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"frr-k8s\",\"env\":[{\"name\":\"KUBERNETES_SERVICE_HOST\",\"value\":\"${api_ip}\"},{\"name\":\"KUBERNETES_SERVICE_PORT\",\"value\":\"6443\"}]}]}}}}" \
    >/dev/null 2>&1 || _warn "Failed to patch frr-k8s-daemon env vars in ${name}"
  _log "Waiting for frr-k8s-daemon rollout in '${name}'..."
  KUBECONFIG="${kubeconfig}" kubectl rollout status -n "${FRR_K8S_NAMESPACE}" \
    daemonset/frr-k8s-daemon --timeout 2m >/dev/null 2>&1 \
    || _warn "frr-k8s-daemon rollout not complete in ${name}"

  # The frr-k8s webhook is unreachable from the kube-apiserver on worker
  # nodes (same ClusterIP issue).  Remove it so FRRConfiguration CRUD
  # does not hang.  The operator-less all-in-one manifest doesn't recreate
  # the webhook configuration automatically.
  KUBECONFIG="${kubeconfig}" kubectl delete validatingwebhookconfiguration \
    frr-k8s-validating-webhook-configuration --ignore-not-found >/dev/null 2>&1 \
    || true
}

install_frr_k8s() {
  local kubeconfig="$1"
  local manifest="/tmp/frr-k8s.yaml"
  if [[ ! -s "${manifest}" ]]; then
    curl -sSL --max-time 60 -o "${manifest}" "${FRR_K8S_MANIFEST_URL}" \
      || _die "Failed to download frr-k8s manifest from ${FRR_K8S_MANIFEST_URL}"
  fi
  # gcr.io/kubebuilder/kube-rbac-proxy is unavailable post GCR shutdown
  if grep -q 'gcr.io/kubebuilder/kube-rbac-proxy' "${manifest}"; then
    sed -i.bak 's|gcr.io/kubebuilder/kube-rbac-proxy|registry.k8s.io/kubebuilder/kube-rbac-proxy|g' "${manifest}" || true
  fi
  # Apply frr-k8s resources (CRDs, RBAC, controllers). Do NOT wait for
  # pod readiness yet — CNI (OVN-K) must be running first.
  KUBECONFIG="${kubeconfig}" kubectl apply -f "${manifest}" >/dev/null
  rm -f "${manifest}" "${manifest}.bak"
}

# OVN-K master writes cniVersion "1.1.0" into /etc/cni/net.d/10-ovn-kubernetes.conf
# but its own CNI plugin rejects that result version. Patch it to "1.0.0" on every
# node and restart any system pods that got stuck during the CNI-not-ready window.
fix_cni_version_and_system_pods() {
  local kubeconfig="$1" name="$2"
  _log "Patching CNI config cniVersion on nodes in '${name}'..."
  local node
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    podman exec "${node}" sed -i 's/"cniVersion":"1.1.0"/"cniVersion":"1.0.0"/' \
      /etc/cni/net.d/10-ovn-kubernetes.conf 2>/dev/null || true
  done < <(KUBECONFIG="${kubeconfig}" kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  _log "Restarting system pods that may have been stuck during CNI startup..."
  KUBECONFIG="${kubeconfig}" kubectl delete pod -n kube-system -l k8s-app=kube-dns --wait=false \
    >/dev/null 2>&1 || true
  KUBECONFIG="${kubeconfig}" kubectl delete pod -n local-path-storage --all --wait=false \
    >/dev/null 2>&1 || true

  _log "Waiting for CoreDNS to become ready in '${name}'..."
  KUBECONFIG="${kubeconfig}" kubectl wait -n kube-system \
    --for=condition=Ready pod -l k8s-app=kube-dns --timeout 2m \
    || _warn "CoreDNS not ready in ${name} within 2m"
  _log "Waiting for local-path-provisioner to become ready in '${name}'..."
  KUBECONFIG="${kubeconfig}" kubectl wait -n local-path-storage \
    --for=condition=Ready pod --all --timeout 2m \
    || _warn "local-path-provisioner not ready in ${name} within 2m"
}

# ---------- Provider Edge (podman FRR containers) ----------

# Get a container's IP on a given podman network.
container_ip_on_network() {
  local container="$1" network="$2"
  podman inspect "${container}" \
    --format "{{(index .NetworkSettings.Networks \"${network}\").IPAddress}}" 2>/dev/null || echo ""
}

# Write complete FRR config for an edge and restart FRR inside the container.
# The frr.conf is bind-mounted from the host; updating the host file is
# reflected immediately in the container (no reload needed for podman binds).
#
# v2: eBGP transit — local_as and remote_as differ for the sites peer-group.
configure_edge() {
  local container="$1" name="$2" site_ip="$3" transit_ip="$4" local_as="$5" remote_as="$6" remote_transit_ip="$7"
  shift 7
  local node_ips=("$@")

  local conf_file="${SCRIPT_DIR}/${name}_frr.conf"

  _log "  configuring ${name} (site=${site_ip}, transit=${transit_ip}, AS=${local_as}, remote=${remote_as}, ${#node_ips[@]} node(s))..."

  {
    cat <<CONF
frr version 10.1
frr defaults traditional
hostname ${name}
log syslog informational
!
router bgp ${local_as}
  no bgp ebgp-requires-policy
  bgp route-reflector allow-outbound-policy
  neighbor ovn peer-group
  neighbor ovn remote-as ${local_as}
  neighbor ovn update-source ${site_ip}
CONF
    local n
    for n in "${node_ips[@]}"; do
      echo "  neighbor ${n} peer-group ovn"
    done
    cat <<CONF
  neighbor sites peer-group
  neighbor sites remote-as ${remote_as}
  neighbor sites update-source ${transit_ip}
  neighbor ${remote_transit_ip} peer-group sites
  !
  address-family ipv4 unicast
    neighbor ovn activate
    neighbor ovn route-reflector-client
    neighbor sites activate
    neighbor sites next-hop-self
  exit-address-family
  address-family l2vpn evpn
    neighbor ovn activate
    neighbor ovn route-reflector-client
    neighbor sites activate
    neighbor sites next-hop-self
    advertise-all-vni
  exit-address-family
!
line vty
!
CONF
  } > "${conf_file}"

  podman restart "${container}" >/dev/null 2>&1 || true
  sleep 2
}

# Shared: after deploy/start, discover IPs and configure both edges.
_configure_edges() {
  local e1_site e2_site e1_transit e2_transit
  e1_site=$(container_ip_on_network "${EDGE1_CONTAINER}" "${SITE1_NETWORK}")
  e2_site=$(container_ip_on_network "${EDGE2_CONTAINER}" "${SITE2_NETWORK}")
  e1_transit=$(container_ip_on_network "${EDGE1_CONTAINER}" "${TRANSIT_NETWORK}")
  e2_transit=$(container_ip_on_network "${EDGE2_CONTAINER}" "${TRANSIT_NETWORK}")

  [[ -n "${e1_site}" && "${e1_site}" != "<no value>" ]] \
    || _die "Could not determine ${EDGE1_CONTAINER} IP on ${SITE1_NETWORK}"
  [[ -n "${e2_site}" && "${e2_site}" != "<no value>" ]] \
    || _die "Could not determine ${EDGE2_CONTAINER} IP on ${SITE2_NETWORK}"
  [[ -n "${e1_transit}" && "${e1_transit}" != "<no value>" ]] \
    || _die "Could not determine ${EDGE1_CONTAINER} IP on ${TRANSIT_NETWORK}"
  [[ -n "${e2_transit}" && "${e2_transit}" != "<no value>" ]] \
    || _die "Could not determine ${EDGE2_CONTAINER} IP on ${TRANSIT_NETWORK}"

  local c1_nodes=() c2_nodes=()
  local n ip
  for n in $(_kind_nodes "${CLUSTER1_NAME}"); do
    ip=$(container_ip_on_network "${n}" "${SITE1_NETWORK}")
    [[ -n "${ip}" && "${ip}" != "<no value>" ]] && c1_nodes+=("${ip}")
  done
  for n in $(_kind_nodes "${CLUSTER2_NAME}"); do
    ip=$(container_ip_on_network "${n}" "${SITE2_NETWORK}")
    [[ -n "${ip}" && "${ip}" != "<no value>" ]] && c2_nodes+=("${ip}")
  done

  # edge1: AS 65001, peers iBGP with cluster1 nodes, eBGP with edge2 (AS 65002)
  configure_edge "${EDGE1_CONTAINER}" edge1 "${e1_site}" "${e1_transit}" \
    "${SITE1_AS}" "${SITE2_AS}" "${e2_transit}" "${c1_nodes[@]}"

  # edge2: AS 65002, peers iBGP with cluster2 nodes, eBGP with edge1 (AS 65001)
  configure_edge "${EDGE2_CONTAINER}" edge2 "${e2_site}" "${e2_transit}" \
    "${SITE2_AS}" "${SITE1_AS}" "${e1_transit}" "${c2_nodes[@]}"
}

# Re-connect edge containers to transit network after podman restart
# (podman restart may drop secondary network attachments).
reconnect_transit_network() {
  local ctr="$1" transit_ip="$2"
  if ! podman inspect "${ctr}" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
     | grep -q "\"${TRANSIT_NETWORK}\""; then
    _log "  Re-connecting ${ctr} to ${TRANSIT_NETWORK}..."
    podman network connect "${TRANSIT_NETWORK}" "${ctr}" --ip "${transit_ip}" >/dev/null 2>&1 || true
  fi
}

# Create stub config files and start both edge containers.
deploy_provider_edge() {
  local ctr name site_ip transit_ip site_network
  for ctr in "${EDGE1_CONTAINER}" "${EDGE2_CONTAINER}"; do
    case "${ctr}" in
      "${EDGE1_CONTAINER}") name=edge1; site_ip="${EDGE1_SITE_IP}"; transit_ip="${EDGE1_TRANSIT_IP}"; site_network="${SITE1_NETWORK}" ;;
      "${EDGE2_CONTAINER}") name=edge2; site_ip="${EDGE2_SITE_IP}"; transit_ip="${EDGE2_TRANSIT_IP}"; site_network="${SITE2_NETWORK}" ;;
    esac
    cat > "${SCRIPT_DIR}/${name}_daemons" <<EOF
bgpd=yes
zebra=yes
EOF
    cat > "${SCRIPT_DIR}/${name}_frr.conf" <<CONF
frr version 10.1
frr defaults traditional
hostname ${name}
log syslog informational
!
line vty
!
CONF
    if podman container exists "${ctr}" 2>/dev/null; then
      _log "Container '${ctr}' exists already; removing..."
      podman rm -f "${ctr}" >/dev/null
    fi
    _log "Creating container '${ctr}' (site=${site_ip} on ${site_network}, transit=${transit_ip})..."
    podman run -d --name "${ctr}" \
      --network "${site_network}":ip="${site_ip}" \
      --network "${TRANSIT_NETWORK}":ip="${transit_ip}" \
      --network "${KIND_NETWORK}" \
      --privileged \
      -v "${SCRIPT_DIR}/${name}_frr.conf:/etc/frr/frr.conf" \
      -v "${SCRIPT_DIR}/${name}_daemons:/etc/frr/daemons" \
      -v "${SCRIPT_DIR}/edge_vtysh.conf:/etc/frr/vtysh.conf" \
      "${FRR_IMAGE}" >/dev/null
  done
  _configure_edges
}

start_provider_edge() {
  for ctr in "${EDGE1_CONTAINER}" "${EDGE2_CONTAINER}"; do
    if podman container exists "${ctr}" 2>/dev/null; then
      _log "Starting '${ctr}'..."
      podman start "${ctr}" >/dev/null
    else
      _die "Container '${ctr}' does not exist. Run 'create' first."
    fi
  done
  sleep 2
  # Re-attach transit network if podman start dropped it
  reconnect_transit_network "${EDGE1_CONTAINER}" "${EDGE1_TRANSIT_IP}"
  reconnect_transit_network "${EDGE2_CONTAINER}" "${EDGE2_TRANSIT_IP}"
  _configure_edges
}

stop_provider_edge() {
  for ctr in "${EDGE1_CONTAINER}" "${EDGE2_CONTAINER}"; do
    if podman container exists "${ctr}" 2>/dev/null; then
      _log "Stopping '${ctr}'..."
      podman stop "${ctr}" >/dev/null 2>&1 || true
    fi
  done
}

destroy_provider_edge() {
  for ctr in "${EDGE1_CONTAINER}" "${EDGE2_CONTAINER}"; do
    if podman container exists "${ctr}" 2>/dev/null; then
      _log "Removing '${ctr}'..."
      podman rm -f "${ctr}" >/dev/null 2>&1 || true
    fi
  done
  rm -f "${SCRIPT_DIR}"/edge{1,2}_{frr.conf,daemons}
}

# Apply per-cluster FRRConfiguration that points frr-k8s to its site edge.
# Per upstream OVN-K kind.sh: l2vpn/evpn is configured on the EXTERNAL FRR
# (the provider edge), not via this CRD. frr-k8s only needs the basic BGP
# neighbor config to peer with the provider edge.
apply_bgp_for_cluster() {
  local kubeconfig="$1" cluster_label="$2" peering_ip="$3" site_as="$4"
  [[ -n "${peering_ip}" ]] || _die "No peering IP provided for ${cluster_label}"

  _log "Probing frr-k8s webhook in ${cluster_label}..."
  local cp_node webhook_svc_ip attempts=0
  cp_node=$(KUBECONFIG="${kubeconfig}" kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].metadata.name}')
  webhook_svc_ip=$(KUBECONFIG="${kubeconfig}" kubectl get svc -n "${FRR_K8S_NAMESPACE}" frr-k8s-webhook-service \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [[ -n "${cp_node}" && -n "${webhook_svc_ip}" ]]; then
    while ! podman exec "${cp_node}" \
        curl -ksS --connect-timeout 1 --max-time 2 "https://${webhook_svc_ip}/" >/dev/null 2>&1; do
      attempts=$((attempts+1))
      if (( attempts > 60 )); then
        _warn "frr-k8s webhook never responded; applying may fail"
        break
      fi
      sleep 1
    done
  fi

  _log "Applying FRRConfiguration to ${cluster_label} (peering IP=${peering_ip}, AS=${site_as})..."
  KUBECONFIG="${kubeconfig}" kubectl apply -f - <<EOF
---
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: evpn
  namespace: ${FRR_K8S_NAMESPACE}
  labels:
    evpn-peer: edge
spec:
  bgp:
    routers:
    - asn: ${site_as}
      neighbors:
      - address: ${peering_ip}
        asn: ${site_as}
        port: 179
        disableMP: false
EOF
  _log "FRRConfiguration applied to ${cluster_label}."
}

# ---------- EVPN stretched L2 (VTEP + CUDN + RouteAdvertisements) ----------

# Create the EVPN workload namespace with the required primary UDN label.
# This label must be present at namespace creation time (validating admission
# policy prevents adding it later).
create_evpn_namespace() {
  local kubeconfig="$1" label="$2"
  _log "Creating EVPN namespace '${EVPN_NAMESPACE}' in ${label}..."
  KUBECONFIG="${kubeconfig}" kubectl delete ns "${EVPN_NAMESPACE}" --ignore-not-found --timeout 30s >/dev/null 2>&1 || true
  KUBECONFIG="${kubeconfig}" kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${EVPN_NAMESPACE}
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
EOF
}

# Apply VTEP, ClusterUserDefinedNetwork, and RouteAdvertisements resources.
apply_evpn_resources() {
  local kubeconfig="$1" label="$2"
  _log "Applying EVPN resources (VTEP, CUDN, RouteAdvertisements) to ${label}..."
  local vtep_cidrs_yaml
  vtep_cidrs_yaml=$(echo "${VTEP_CIDRS}" | tr ',' '\n' | sed 's/^/    - /')
  KUBECONFIG="${kubeconfig}" kubectl apply -f - <<EOF
---
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  mode: Unmanaged
  cidrs:
${vtep_cidrs_yaml}
---
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: ${CUDN_NAME}
  labels:
    evpn: enabled
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${EVPN_NAMESPACE}
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
        - ${CUDN_SUBNETS}
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: ${CUDN_VNI}
        routeTarget: "${ROUTE_TARGET}"
---
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-ra
spec:
  targetVRF: auto
  advertisements:
    - PodNetwork
  nodeSelector: {}
  frrConfigurationSelector:
    matchLabels:
      evpn-peer: edge
  networkSelectors:
    - networkSelectionType: ClusterUserDefinedNetworks
      clusterUserDefinedNetworkSelector:
        networkSelector:
          matchLabels:
            evpn: enabled
EOF
}

# Wait for VTEP, CUDN, and RouteAdvertisements to be accepted.
wait_for_evpn_resources() {
  local kubeconfig="$1" label="$2"
  _log "Waiting for EVPN resources to be accepted in ${label}..."

  local deadline=$(($(date +%s) + 180))
  local ok=0
  while (( $(date +%s) < deadline )); do
    local vtep_ok cudn_ok ra_ok
    vtep_ok=$(KUBECONFIG="${kubeconfig}" kubectl get vtep evpn-vtep -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")
    cudn_ok=$(KUBECONFIG="${kubeconfig}" kubectl get clusteruserdefinednetwork "${CUDN_NAME}" -o jsonpath='{.status.conditions[?(@.type=="NetworkCreated")].status}' 2>/dev/null || echo "False")
    ra_ok=$(KUBECONFIG="${kubeconfig}" kubectl get routeadvertisements evpn-ra -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "False")

    if [[ "${vtep_ok}" == "True" && "${cudn_ok}" == "True" && "${ra_ok}" == "True" ]]; then
      ok=1; break
    fi
    sleep 3
  done

  if [[ "${ok}" -eq 1 ]]; then
    _log "EVPN resources accepted in ${label}."
  else
    _warn "EVPN resources may not be fully accepted in ${label}."
    KUBECONFIG="${kubeconfig}" kubectl get vtep,cudn,routeadvertisements -o wide 2>/dev/null | sed 's/^/  /' || true
  fi
}

# ---------- Status ----------

cmd_status() {
  _log "=== Podman networks ==="
  printf '  %-40s %s\n' NAME DRIVER
  while IFS=$'\t' read -r name driver; do
    case "${name}" in
      "${KIND_NETWORK}"|"${SITE1_NETWORK}"|"${SITE2_NETWORK}"|"${TRANSIT_NETWORK}")
        printf '  \033[1;32m%-40s %s\033[0m\n' "${name}" "${driver}" ;;
      *)
        printf '  %-40s %s\n' "${name}" "${driver}" ;;
    esac
  done < <(podman network ls --format '{{.Name}}	{{.Driver}}' 2>/dev/null)
  echo
  _log "=== Kind clusters ==="
  if kind get clusters 2>/dev/null | grep -q .; then
    while read -r name; do
      local marker=""
      case "${name}" in
        "${CLUSTER1_NAME}"|"${CLUSTER2_NAME}") marker=" (managed by this script)" ;;
      esac
      printf '  %s%s\n' "${name}" "${marker}"
    done < <(kind get clusters 2>/dev/null)
  else
    echo "  (none)"
  fi
  echo
  for c in "${CLUSTER1_NAME}" "${CLUSTER2_NAME}"; do
    if kind get clusters 2>/dev/null | grep -qx "${c}"; then
      _log "=== ${c} nodes ==="
      local kc="${SCRIPT_DIR}/kubeconfig.${c}"
      [[ -f "${kc}" ]] || kc="${HOME}/.kube/config"
      KUBECONFIG="${kc}" kubectl get nodes --no-headers 2>/dev/null | sed 's/^/  /' \
        || echo "  (kubectl failed)"
      local site_net
      case "${c}" in
        "${CLUSTER1_NAME}") site_net="${SITE1_NETWORK}" ;;
        "${CLUSTER2_NAME}") site_net="${SITE2_NETWORK}" ;;
      esac
      for n in $(_kind_nodes "${c}"); do
        local site_ip
        site_ip=$(container_ip_on_network "${n}" "${site_net}")
        printf '    %-30s %s=%s\n' "${n}" "${site_net}" "${site_ip:-<none>}"
      done
    fi
  done
  echo
  _log "=== Provider Edge (podman) ==="
  for ctr in "${EDGE1_CONTAINER}" "${EDGE2_CONTAINER}"; do
    if podman container exists "${ctr}" 2>/dev/null; then
      local state site_ip transit_ip
      state=$(podman inspect --format '{{.State.Status}}' "${ctr}" 2>/dev/null)
      case "${ctr}" in
        "${EDGE1_CONTAINER}") site_ip=$(container_ip_on_network "${ctr}" "${SITE1_NETWORK}"); transit_ip=$(container_ip_on_network "${ctr}" "${TRANSIT_NETWORK}") ;;
        "${EDGE2_CONTAINER}") site_ip=$(container_ip_on_network "${ctr}" "${SITE2_NETWORK}"); transit_ip=$(container_ip_on_network "${ctr}" "${TRANSIT_NETWORK}") ;;
      esac
      printf '  %-20s state=%-10s site=%-16s transit=%s\n' "${ctr}" "${state}" "${site_ip:-<none>}" "${transit_ip:-<none>}"
      if [[ "${state}" == "running" ]]; then
        podman exec "${ctr}" vtysh -c "show bgp summary" 2>/dev/null | sed 's/^/    /' || true
        echo
        _log "  ${ctr} EVPN routes:"
        podman exec "${ctr}" vtysh -c "show bgp l2vpn evpn" 2>/dev/null | sed 's/^/      /' || true
      fi
    else
      printf '  %-20s (not created)\n' "${ctr}"
    fi
  done
  echo
  for c in "${CLUSTER1_NAME}" "${CLUSTER2_NAME}"; do
    if kind get clusters 2>/dev/null | grep -qx "${c}"; then
      _log "=== ${c} EVPN resources ==="
      local kc="${SCRIPT_DIR}/kubeconfig.${c}"
      [[ -f "${kc}" ]] || kc="${HOME}/.kube/config"
      KUBECONFIG="${kc}" kubectl get vtep,cudn,routeadvertisements,frrconfiguration -A -o wide 2>/dev/null | sed 's/^/  /' \
        || echo "  (kubectl failed)"
    fi
  done
}

# ---------- Subcommands ----------

cmd_create() {
  local skip_evpn=0
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--skip-evpn" ]]; then
      skip_evpn=1
    fi
  done

  check_deps full
  ensure_kind_network
  ensure_site_networks
  ensure_kernel_modules
  ensure_ovn_k_repo
  ensure_ovn_k_image

  mkdir -p "${STATE_DIR}"
  : > "${STATE_DIR}/created"

  render_kind_config "${CLUSTER1_NAME}" "${CLUSTER1_POD_CIDR}" "${CLUSTER1_SVC_CIDR}" "${KIND_CONFIG_C1}"
  render_kind_config "${CLUSTER2_NAME}" "${CLUSTER2_POD_CIDR}" "${CLUSTER2_SVC_CIDR}" "${KIND_CONFIG_C2}"

  _kind_create "${CLUSTER1_NAME}" "${KIND_CONFIG_C1}" "${KUBECONFIG_C1}"
  connect_nodes_to_site_network "${CLUSTER1_NAME}" "${SITE1_NETWORK}"

  _kind_create "${CLUSTER2_NAME}" "${KIND_CONFIG_C2}" "${KUBECONFIG_C2}"
  connect_nodes_to_site_network "${CLUSTER2_NAME}" "${SITE2_NETWORK}"

  install_ovn_k_in_cluster "${CLUSTER1_NAME}" "${KUBECONFIG_C1}" "${CLUSTER1_POD_CIDR}" "${CLUSTER1_SVC_CIDR}"
  install_ovn_k_in_cluster "${CLUSTER2_NAME}" "${KUBECONFIG_C2}" "${CLUSTER2_POD_CIDR}" "${CLUSTER2_SVC_CIDR}"

  deploy_provider_edge
  apply_bgp_for_cluster "${KUBECONFIG_C1}" "${CLUSTER1_NAME}" "${EDGE1_SITE_IP}" "${SITE1_AS}"
  apply_bgp_for_cluster "${KUBECONFIG_C2}" "${CLUSTER2_NAME}" "${EDGE2_SITE_IP}" "${SITE2_AS}"

  # Wire up the EVPN stretched L2 fabric (VTEP, CUDN, RouteAdvertisements)
  if [[ "${skip_evpn}" -eq 0 ]]; then
    create_evpn_namespace "${KUBECONFIG_C1}" "${CLUSTER1_NAME}"
    create_evpn_namespace "${KUBECONFIG_C2}" "${CLUSTER2_NAME}"
    apply_evpn_resources "${KUBECONFIG_C1}" "${CLUSTER1_NAME}"
    apply_evpn_resources "${KUBECONFIG_C2}" "${CLUSTER2_NAME}"
    wait_for_evpn_resources "${KUBECONFIG_C1}" "${CLUSTER1_NAME}"
    wait_for_evpn_resources "${KUBECONFIG_C2}" "${CLUSTER2_NAME}"
  else
    _log "Skipping EVPN stretched fabric setup (per --skip-evpn option)."
  fi

  _log "✅ Done. Kubeconfigs:"
  echo "  ${CLUSTER1_NAME}: ${KUBECONFIG_C1}"
  echo "  ${CLUSTER2_NAME}: ${KUBECONFIG_C2}"
  _log "Try:  KUBECONFIG=${KUBECONFIG_C1} kubectl get nodes"
}

cmd_destroy() {
  check_deps minimal
  destroy_provider_edge
  for c in "${CLUSTER1_NAME}" "${CLUSTER2_NAME}"; do
    _kind_delete "${c}"
  done
  rm -f "${KIND_CONFIG_C1}" "${KIND_CONFIG_C2}" \
    "${KUBECONFIG_C1}" "${KUBECONFIG_C2}"
  rm -rf "${STATE_DIR}"
  remove_site_networks
  maybe_remove_kind_network
  _log "✅ Destroyed."
}

cmd_stop() {
  check_deps minimal
  for c in "${CLUSTER1_NAME}" "${CLUSTER2_NAME}"; do
    if kind get clusters 2>/dev/null | grep -qx "${c}"; then
      _log "Stopping kind cluster '${c}'..."
      _kind_stop "${c}"
    else
      _log "Kind cluster '${c}' not present."
    fi
  done
  stop_provider_edge
  _log "✅ Stopped."
}

cmd_start() {
  check_deps minimal
  start_provider_edge
  for c in "${CLUSTER1_NAME}" "${CLUSTER2_NAME}"; do
    if kind get clusters 2>/dev/null | grep -qx "${c}"; then
      _log "Starting kind cluster '${c}'..."
      _kind_start "${c}"
    else
      _die "Kind cluster '${c}' not found. Run 'create' first."
    fi
  done
  _log "✅ Started. BGP sessions will re-establish within ~30s."
}

cmd_help() {
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "  ui build     Build the evpn-ui container image"
  echo "  ui start     Start the evpn-ui container (port 8080)"
  echo "  ui stop      Stop the evpn-ui container"
  echo "  ui status    Show UI container status and URL"
  echo "  ui logs      Follow UI container logs"
}

# ---------- Web UI ----------

UI_IMAGE="${UI_IMAGE:-evpn-ui:latest}"
UI_CONTAINER="${UI_CONTAINER:-evpn-ui}"
UI_PORT="${UI_PORT:-8080}"
UI_DOCKERFILE="${SCRIPT_DIR}/ui/Dockerfile"

cmd_ui() {
  local ui_cmd="${1:-start}"
  shift || true
  case "${ui_cmd}" in
    build)
      _log "Building evpn-ui image..."
      podman build -t "${UI_IMAGE}" -f "${UI_DOCKERFILE}" "${SCRIPT_DIR}/ui"
      _log "✅ Image built: ${UI_IMAGE}"
      ;;
    start)
      if podman container exists "${UI_CONTAINER}" 2>/dev/null; then
        if [[ "$(podman inspect --format '{{.State.Status}}' "${UI_CONTAINER}" 2>/dev/null)" == "running" ]]; then
          _log "UI container already running at http://localhost:${UI_PORT}"
          return
        fi
        podman start "${UI_CONTAINER}" >/dev/null
        _log "✅ UI started at http://localhost:${UI_PORT}"
        return
      fi
      if ! podman image exists "${UI_IMAGE}" 2>/dev/null; then
        _log "Image not found; building..."
        podman build -t "${UI_IMAGE}" -f "${UI_DOCKERFILE}" "${SCRIPT_DIR}/ui"
      fi
      _log "Launching evpn-ui container..."
      podman run -d --name "${UI_CONTAINER}" \
        --network "${SITE1_NETWORK}" \
        --network "${SITE2_NETWORK}" \
        --network "${TRANSIT_NETWORK}" \
        --network "${KIND_NETWORK}" \
        --privileged \
        -p "${UI_PORT}:8080" \
        -v /var/run/docker.sock:/run/podman/podman.sock:rw \
        "${UI_IMAGE}" \
        --cluster1 "${CLUSTER1_NAME}" \
        --cluster2 "${CLUSTER2_NAME}"
      _log "✅ UI running at http://localhost:${UI_PORT}"
      ;;
    stop)
      if podman container exists "${UI_CONTAINER}" 2>/dev/null; then
        podman stop "${UI_CONTAINER}" >/dev/null 2>&1 || true
        _log "UI container stopped."
      else
        _log "UI container not found."
      fi
      ;;
    status)
      if podman container exists "${UI_CONTAINER}" 2>/dev/null; then
        local state
        state=$(podman inspect --format '{{.State.Status}}' "${UI_CONTAINER}" 2>/dev/null)
        echo "  UI container: ${UI_CONTAINER} (${state})"
        if [[ "${state}" == "running" ]]; then
          echo "  URL: http://localhost:${UI_PORT}"
        fi
      else
        echo "  UI container: not created"
      fi
      ;;
    logs)
      podman logs -f "${UI_CONTAINER}" 2>/dev/null || _die "UI container not found. Run 'ui start' first."
      ;;
    *)
      _die "Unknown ui subcommand: ${ui_cmd}. Try: build | start | stop | status | logs"
      ;;
  esac
}

# ---------- Main ----------

main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    create)   cmd_create "$@" ;;
    destroy)  cmd_destroy "$@" ;;
    stop)     cmd_stop "$@" ;;
    start)    cmd_start "$@" ;;
    status)   cmd_status "$@" ;;
    ui)       cmd_ui "$@" ;;
    help|-h|--help) cmd_help ;;
    *) _die "Unknown subcommand: ${cmd}. Try: create | destroy | start | stop | status | ui | help" ;;
  esac
}

main "$@"
