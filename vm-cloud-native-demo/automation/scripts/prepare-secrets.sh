#!/usr/bin/env bash
set -euo pipefail
: "${NAMESPACE:?Set NAMESPACE to the demo namespace}"
: "${PRIVATE_DIR:?Set PRIVATE_DIR to a private persistent directory}"
SSH_KEY=${SSH_KEY:-"$HOME/.ssh/rh-demos"}
[[ -f "$SSH_KEY" && -f "$SSH_KEY.pub" ]] || { echo 'SSH private and public keys are required' >&2; exit 1; }
umask 077
mkdir -p "$PRIVATE_DIR"
AUTOMATION_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(git -C "$AUTOMATION_DIR" rev-parse --show-toplevel 2>/dev/null || true)
private_real=$(cd "$PRIVATE_DIR" && pwd -P)
if [[ -n "$repo_root" ]]; then
  repo_real=$(cd "$repo_root" && pwd -P)
  case "$private_real/" in
    "$repo_real/"*) echo 'PRIVATE_DIR must be outside the Git repository' >&2; exit 1 ;;
  esac
fi
chmod 700 "$PRIVATE_DIR"
secret_matches_file() {
  local secret=$1 field=$2 file=$3 expected actual
  expected=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$file")
  actual=$(oc -n "$NAMESPACE" get secret "$secret" -o json | ruby -rjson -rbase64 -rdigest -e 'data=JSON.parse(STDIN.read).fetch("data").fetch(ARGV.fetch(0)); print Digest::SHA256.hexdigest(Base64.strict_decode64(data))' "$field")
  [[ "$expected" == "$actual" ]] || { echo "Secret $secret does not match $file; refusing to rotate or continue" >&2; return 1; }
}
for tier in db app web; do
  key="$PRIVATE_DIR/host-$tier"
  if [[ ! -f "$key" && ! -f "$key.pub" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$key"
  fi
  [[ -f "$key" && -f "$key.pub" ]] || { echo "Incomplete host key for $tier" >&2; exit 1; }
  TIER="$tier" SSH_KEY="$SSH_KEY" PRIVATE_DIR="$PRIVATE_DIR" ruby -ryaml -e '
    tier=ENV.fetch("TIER"); dir=ENV.fetch("PRIVATE_DIR"); userkey=File.read(ENV.fetch("SSH_KEY")+".pub").strip
    data={"users"=>[{"name"=>"demo-automation","groups"=>["wheel"],"sudo"=>"ALL=(ALL) NOPASSWD:ALL","shell"=>"/bin/bash","ssh_authorized_keys"=>[userkey]}],"ssh_pwauth"=>false,"ssh_keys"=>{"ed25519_private"=>File.read("#{dir}/host-#{tier}"),"ed25519_public"=>File.read("#{dir}/host-#{tier}.pub").strip}}
    File.write("#{dir}/#{tier}-userdata", "#cloud-config\n"+YAML.dump(data).sub(/\A---\s*\n/, ""))
  '
  if ! oc -n "$NAMESPACE" get secret "orders-$tier-cloudinit" >/dev/null 2>&1; then
    oc -n "$NAMESPACE" create secret generic "orders-$tier-cloudinit" --from-file="userdata=$PRIVATE_DIR/$tier-userdata"
  else
    secret_matches_file "orders-$tier-cloudinit" userdata "$PRIVATE_DIR/$tier-userdata"
    echo "Secret orders-$tier-cloudinit exists and matches; retaining it."
  fi
done
: > "$PRIVATE_DIR/known_hosts"
for tier in db app web; do
  awk -v name="orders-$tier" '{print name " " $1 " " $2}' "$PRIVATE_DIR/host-$tier.pub" >> "$PRIVATE_DIR/known_hosts"
done
if ! oc -n "$NAMESPACE" get secret orders-automation-ssh >/dev/null 2>&1; then
  oc -n "$NAMESPACE" create secret generic orders-automation-ssh --from-file="id_rsa=$SSH_KEY" --from-file="known_hosts=$PRIVATE_DIR/known_hosts"
else
  secret_matches_file orders-automation-ssh id_rsa "$SSH_KEY"
  secret_matches_file orders-automation-ssh known_hosts "$PRIVATE_DIR/known_hosts"
  echo 'Secret orders-automation-ssh exists and matches; retaining it.'
fi
if [[ ! -f "$PRIVATE_DIR/db-password" ]]; then
  ruby -rsecurerandom -e 'print SecureRandom.hex(24)' > "$PRIVATE_DIR/db-password"
fi
if ! oc -n "$NAMESPACE" get secret orders-database-credentials >/dev/null 2>&1; then
  oc -n "$NAMESPACE" create secret generic orders-database-credentials --from-file="password=$PRIVATE_DIR/db-password"
else
  secret_matches_file orders-database-credentials password "$PRIVATE_DIR/db-password"
  echo 'Secret orders-database-credentials exists and matches; retaining it.'
fi
printf 'SSH and database secrets are prepared; private setup files are in %s\n' "$PRIVATE_DIR"
