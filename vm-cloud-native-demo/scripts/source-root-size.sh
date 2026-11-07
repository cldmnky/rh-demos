#!/usr/bin/env bash
# Read the clone's minimum disk size without changing the managed DataSource.
set -euo pipefail
namespace=${1:?Usage: source-root-size.sh NAMESPACE DATASOURCE}
name=${2:?Usage: source-root-size.sh NAMESPACE DATASOURCE}
source_ref=$(oc --request-timeout=15s -n "$namespace" get datasource "$name" -o json | ruby -rjson -e '
  ds=JSON.parse(STDIN.read)
  ready=ds.dig("status","conditions").to_a.any? { |c| c["type"] == "Ready" && c["status"] == "True" }
  abort "RHEL DataSource is not ready" unless ready
  source=ds.dig("status","source") || ds.dig("spec","source") || {}
  kind=%w[snapshot pvc].find { |k| !source.dig(k,"name").to_s.empty? }
  abort "RHEL DataSource must reference a VolumeSnapshot or PVC" unless kind
  ref=source.fetch(kind)
  puts [kind == "snapshot" ? "volumesnapshot" : "pvc", ref["namespace"] || ds.fetch("metadata").fetch("namespace"), ref.fetch("name")].join("\t")
')
IFS=$'\t' read -r kind source_namespace source_name <<< "$source_ref"
oc --request-timeout=15s -n "$source_namespace" get "$kind" "$source_name" -o json | SOURCE_KIND="$kind" ruby -rjson -e '
  source=JSON.parse(STDIN.read)
  abort "RHEL clone source is being deleted" if source.dig("metadata","deletionTimestamp")
  if ENV.fetch("SOURCE_KIND") == "volumesnapshot"
    abort "RHEL source snapshot is not ready to use" unless source.dig("status","readyToUse") == true
    size=source.dig("status","restoreSize")
  else
    size=source.dig("spec","resources","requests","storage")
  end
  abort "Cannot determine RHEL clone source disk size" if size.to_s.empty?
  puts size
'
