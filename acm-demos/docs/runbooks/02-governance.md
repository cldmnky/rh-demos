# Act 2 — detect, enforce, and correct drift

**16:00–29:00 · 13 minutes.** ACM Governance → precise target evidence → compliance result.
Starting state: `$GOVERNANCE_RELEASE` in `$POLICY_NS`, inform and NonCompliant; harmless baseline
absent/incorrect on production; excluded target unchanged. Policy alone owns the baseline.

Local inputs: `governance-inform.local.yaml` and `governance-enforce.local.yaml`. They must select
the intended production target, exclude the hub, and agree on target namespace/value. `$BASELINE_NS`
is derived by the shell initializer. Do not display unrelated private values.

## 1. CONSOLE — ask the compliance question (16:00–19:00)

All Clusters → Governance → Policies → `$GOVERNANCE_RELEASE` → Details / cluster compliance.
Point to one concrete NonCompliant message, the production target, and required baseline value.
**Say:** “This harmless ConfigMap isolates governance behavior: observe a missing requirement,
choose remediation, then prove unrelated clusters remain untouched.”

## 2. TERMINAL — prove selection and inform-only behavior (19:00–21:00)

```bash
oc_hub get placementdecisions -n "$POLICY_NS" \
  -l "cluster.open-cluster-management.io/placement=$GOVERNANCE_RELEASE" -o json |
  jq -r '.items[].status.decisions[] | .clusterName'
oc_hub get policy "$GOVERNANCE_RELEASE" -n "$POLICY_NS" -o json |
  jq '{compliance:.status.compliant,
       remediation:.spec["policy-templates"][0].objectDefinition.spec.remediationAction}'
oc_prod get configmap demo-security-baseline -n "$BASELINE_NS" --ignore-not-found
```

Expect exactly the production target and no creation/correction under inform. An initially absent
namespace may also produce NotFound; explain that expected baseline absence once. **Say:**
“NonCompliant is an observation. Inform has reported a difference without correcting it.”

## 3. ADVANCE — enforce through the existing owner (21:00–24:00)

If the rehearsed intent owner is CLI Helm, the authorized operator uses:

```bash
scripts/setup-demo.sh governance-enforce --apply
```

If Git owns intent, use its prepared change instead; never add a second owner. Observe in the
console, then prove the actual target value:

```bash
oc_hub wait "policy/$GOVERNANCE_RELEASE" -n "$POLICY_NS" \
  --for=jsonpath='{.status.compliant}'=Compliant --timeout=90s
oc_prod get configmap demo-security-baseline -n "$BASELINE_NS" -o json |
  jq '{name:.metadata.name,namespace:.metadata.namespace,data:.data}'
```

**Say:** “The definition is central. The correction happened on the selected cluster. Green
compliance is useful; the target object is the proof.” Parent/embedded remediation must not conflict.

## 4. ADVANCE — deliberately drift one demo-owned field (24:00–26:00)

After explicit drift authorization:

```bash
scripts/drift-demo.sh --apply
```

The script checks production identity, confirms the exact demo target, changes only
`security-profile`, and waits up to 60 seconds for the local policy controller to restore the
configured value. It refuses non-demo namespaces. **Say:** “This is continuous reconciliation,
not a one-time apply.” Remediation may beat UI refresh; do not promise a visible red transition
or claim an immediately successful wait measures detection latency.

## 5. CONSOLE / TERMINAL — prove exclusion (26:00–28:00)

Show the selected-cluster list, then:

```bash
oc_excluded get namespace "$BASELINE_NS" --ignore-not-found
```

Expect no baseline namespace on the prepared negative target. If it legitimately existed before
this demo, compare its known initial state instead of claiming absence. **Say:** “Fleet-wide
doesn't mean every cluster. Placement is part of the control.”

## 6. LAND — application delivery (28:00–29:00)

“We have an available cluster and a controlled baseline. Now keep the application constant and
change its delivery controller.” Switch to subscription topology. One bounded check if status
lags; no selector widening or reset on stage. Restore inform through the same owner afterward.
