#!/bin/bash

set -e
set -u
set -o pipefail

OPERATOR_PACKAGE="${OPERATOR_PACKAGE:-openshift-cert-manager-operator}"
UPGRADE_CHANNEL="${UPGRADE_CHANNEL:-stable-v1.19}"
NAMESPACE="openshift-cert-manager-operator"
STAGED_CATALOG_NAME="cert-manager-staged"
TIMEOUT=600
CERT_MANAGER_NS="cert-manager"
PASS_COUNT=0
FAIL_COUNT=0

function log_info() { echo "[INFO] $1"; }
function log_pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "[PASS] $1"; }
function log_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "[FAIL] $1"; }

function setup_registry_auth() {
    local vault_path="/var/run/vault/mirror-registry"
    if [[ ! -d "$vault_path" ]]; then
        log_info "No vault credentials found, assuming auth is pre-configured"
        return 0
    fi

    log_info "Injecting stage registry auth into cluster pull-secret..."
    local stage_registry_path="${vault_path}/registry_stage.json"

    oc extract secret/pull-secret -n openshift-config --confirm --to /tmp
    if [[ -f "$stage_registry_path" ]]; then
        local stage_user stage_pass stage_auth
        stage_user=$(jq -r '.user' "$stage_registry_path")
        stage_pass=$(jq -r '.password' "$stage_registry_path")
        stage_auth=$(echo -n "${stage_user}:${stage_pass}" | base64 -w 0)
        jq --argjson stage "{\"registry.stage.redhat.io\": {\"auth\": \"${stage_auth}\"}}" \
            '.auths |= . + $stage' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
        oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson
        log_info "Stage registry auth merged into pull-secret"
        sleep 30
    fi
}

function discover_upgrade_paths() {
    local catalog_dir=""
    # Find catalog dir from source checkout matching OCP version
    local ocp_version
    ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    local ocp_minor
    ocp_minor=$(echo "$ocp_version" | cut -d. -f1,2)

    for dir in "${ARTIFACT_DIR}/../src/catalogs/v${ocp_minor}" \
               "/go/src/github.com/openshift/cert-manager-operator-release/catalogs/v${ocp_minor}"; do
        if [[ -d "$dir/catalog/${OPERATOR_PACKAGE}" ]]; then
            catalog_dir="$dir/catalog/${OPERATOR_PACKAGE}"
            break
        fi
    done

    if [[ -z "$catalog_dir" ]]; then
        echo "WARNING: Could not find catalog directory for OCP ${ocp_minor}, trying v4.21"
        catalog_dir="/go/src/github.com/openshift/cert-manager-operator-release/catalogs/v4.21/catalog/${OPERATOR_PACKAGE}"
    fi

    if [[ -n "${FROM_VERSION:-}" ]]; then
        echo "$FROM_VERSION"
        return
    fi

    local channel_file="${catalog_dir}/channel.yaml"
    if [[ ! -f "$channel_file" ]]; then
        echo "ERROR: channel.yaml not found at ${channel_file}" >&2
        exit 1
    fi

    python3 -c "
import yaml, sys
with open('${channel_file}') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if not doc or doc.get('name') != '${UPGRADE_CHANNEL}':
        continue
    entries = doc.get('entries', [])
    head = entries[-1]
    replaces = head.get('replaces', '')
    if replaces:
        print(replaces.split('.v')[-1])
    for skip in head.get('skips', []):
        print(skip.split('.v')[-1])
    sys.exit(0)
print('ERROR: channel not found', file=sys.stderr)
sys.exit(1)
"
}

function get_target_version() {
    local catalog_dir=""
    local ocp_version
    ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    local ocp_minor
    ocp_minor=$(echo "$ocp_version" | cut -d. -f1,2)

    for dir in "${ARTIFACT_DIR}/../src/catalogs/v${ocp_minor}" \
               "/go/src/github.com/openshift/cert-manager-operator-release/catalogs/v${ocp_minor}"; do
        if [[ -d "$dir/catalog/${OPERATOR_PACKAGE}" ]]; then
            catalog_dir="$dir/catalog/${OPERATOR_PACKAGE}"
            break
        fi
    done

    if [[ -z "$catalog_dir" ]]; then
        catalog_dir="/go/src/github.com/openshift/cert-manager-operator-release/catalogs/v4.21/catalog/${OPERATOR_PACKAGE}"
    fi

    local channel_file="${catalog_dir}/channel.yaml"
    python3 -c "
import yaml, sys
with open('${channel_file}') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if not doc or doc.get('name') != '${UPGRADE_CHANNEL}':
        continue
    entries = doc.get('entries', [])
    head = entries[-1]
    print(head['name'].split('.v')[-1])
    sys.exit(0)
sys.exit(1)
"
}

function install_from_prod() {
    local version="$1"
    local csv_name="${OPERATOR_PACKAGE}.v${version}"
    log_info "Installing ${csv_name} from redhat-operators..."

    oc get namespace "$NAMESPACE" 2>/dev/null || oc create namespace "$NAMESPACE"

    if ! oc get operatorgroup -n "$NAMESPACE" 2>/dev/null | grep -q .; then
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
EOF
    fi

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_PACKAGE}
  namespace: ${NAMESPACE}
spec:
  channel: ${UPGRADE_CHANNEL}
  installPlanApproval: Manual
  name: ${OPERATOR_PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${csv_name}
EOF

    log_info "Waiting for InstallPlan..."
    local counter=0
    local ip_name=""
    while [[ $counter -lt $TIMEOUT ]]; do
        ip_name=$(oc get installplan -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null | awk '{print $1}')
        if [[ -n "$ip_name" ]]; then break; fi
        sleep 10
        counter=$((counter + 10))
    done

    if [[ -z "$ip_name" ]]; then
        log_fail "No InstallPlan for ${csv_name} within ${TIMEOUT}s"
        log_info "Diagnostic: subscription conditions:"
        oc get subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | \
            python3 -c "import json,sys; [print(f'  {c[\"type\"]}: {c[\"status\"]} - {c.get(\"reason\",\"\")} {c.get(\"message\",\"\")[:200]}') for c in json.loads(sys.stdin.read() or '[]')]" 2>/dev/null || true
        return 1
    fi

    oc patch installplan "$ip_name" -n "$NAMESPACE" --type merge -p '{"spec":{"approved":true}}'
    log_info "Approved InstallPlan: ${ip_name}"

    if ! wait_for_csv "$csv_name"; then
        log_fail "CSV ${csv_name} did not reach Succeeded"
        return 1
    fi
    log_pass "Installed ${csv_name} from production catalog"
}

function wait_for_csv() {
    local csv_name="$1"
    local counter=0
    while [[ $counter -lt $TIMEOUT ]]; do
        local phase
        phase=$(oc get csv "$csv_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Succeeded" ]]; then return 0; fi
        if [[ "$phase" == "Failed" ]]; then
            oc get csv "$csv_name" -n "$NAMESPACE" -o jsonpath='{.status.message}' || true
            return 1
        fi
        sleep 10
        counter=$((counter + 10))
    done
    return 1
}

function swap_to_staged_catalog() {
    log_info "Creating staged CatalogSource from ${STAGED_INDEX_IMAGE}..."

    # Create CatalogSource FIRST and wait for it to be READY
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${STAGED_CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${STAGED_INDEX_IMAGE}
  displayName: Cert-Manager Staged
  publisher: Red Hat (staging)
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

    local counter=0
    while [[ $counter -lt 120 ]]; do
        local state
        state=$(oc get catalogsource "${STAGED_CATALOG_NAME}" -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [[ "$state" == "READY" ]]; then
            log_info "Staged CatalogSource READY"
            break
        fi
        sleep 10
        counter=$((counter + 10))
    done
    if [[ "$state" != "READY" ]]; then
        log_fail "Staged CatalogSource did not become READY"
        oc get catalogsource "${STAGED_CATALOG_NAME}" -n openshift-marketplace -o yaml || true
        return 1
    fi

    # NOW patch subscription source (catalog is already serving)
    log_info "Patching subscription source to ${STAGED_CATALOG_NAME}..."
    oc patch subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --type merge \
        -p "{\"spec\":{\"source\":\"${STAGED_CATALOG_NAME}\"}}"

    # Remove startingCSV to allow OLM to resolve to channel head
    oc patch subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --type json \
        -p '[{"op": "remove", "path": "/spec/startingCSV"}]' 2>/dev/null || true

    log_info "Subscription source swapped to staged catalog"
}

function approve_upgrade() {
    local target_csv="${OPERATOR_PACKAGE}.v${TARGET_VERSION}"
    log_info "Waiting for upgrade InstallPlan to ${target_csv}..."

    local counter=0
    local ip_name=""
    while [[ $counter -lt $TIMEOUT ]]; do
        ip_name=$(oc get installplan -n "$NAMESPACE" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item['spec'].get('approved', True):
        continue
    if '${target_csv}' in item['spec'].get('clusterServiceVersionNames', []):
        print(item['metadata']['name'])
        break
" 2>/dev/null || echo "")
        if [[ -n "$ip_name" ]]; then break; fi
        sleep 10
        counter=$((counter + 10))
    done

    if [[ -z "$ip_name" ]]; then
        log_fail "No upgrade InstallPlan for ${target_csv} within ${TIMEOUT}s"
        log_info "Diagnostic: subscription conditions:"
        oc get subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | \
            python3 -c "import json,sys; [print(f'  {c[\"type\"]}: {c[\"status\"]} - {c.get(\"reason\",\"\")} {c.get(\"message\",\"\")[:200]}') for c in json.loads(sys.stdin.read() or '[]')]" 2>/dev/null || true
        log_info "Diagnostic: install plans:"
        oc get installplan -n "$NAMESPACE" -o wide 2>/dev/null || true
        return 1
    fi

    oc patch installplan "$ip_name" -n "$NAMESPACE" --type merge -p '{"spec":{"approved":true}}'
    if ! wait_for_csv "$target_csv"; then
        log_fail "Upgrade CSV ${target_csv} did not succeed"
        return 1
    fi
    log_pass "Upgraded to ${target_csv}"
}

function verify_operands() {
    log_info "Verifying operand health..."
    local deployments=("cert-manager" "cert-manager-cainjector" "cert-manager-webhook")
    for dep in "${deployments[@]}"; do
        local counter=0
        local ready="0"
        while [[ $counter -lt 120 ]]; do
            ready=$(oc get deployment "$dep" -n "$CERT_MANAGER_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "${ready:-0}" -ge 1 ]]; then break; fi
            sleep 5
            counter=$((counter + 5))
        done
        if [[ "${ready:-0}" -ge 1 ]]; then
            log_pass "Operand ${dep}: ready"
        else
            log_fail "Operand ${dep}: not ready"
        fi
    done
}

function smoke_test() {
    local test_ns="cert-manager-smoke-test"
    log_info "Running cert issuance smoke test..."

    oc create namespace "$test_ns" 2>/dev/null || true

    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: ${test_ns}
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: ${test_ns}
spec:
  secretName: test-cert-tls
  duration: 2160h
  issuerRef:
    name: selfsigned
    kind: Issuer
  dnsNames:
  - test.example.com
EOF

    local counter=0
    while [[ $counter -lt 60 ]]; do
        local ready
        ready=$(oc get certificate test-cert -n "$test_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == "True" ]]; then
            log_pass "Smoke test: cert issued successfully"
            oc delete namespace "$test_ns" --wait=false 2>/dev/null || true
            return 0
        fi
        sleep 3
        counter=$((counter + 3))
    done
    log_fail "Smoke test: cert not ready within 60s"
    oc delete namespace "$test_ns" --wait=false 2>/dev/null || true
    return 1
}

function cleanup() {
    log_info "Cleaning up..."
    oc delete subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    oc delete csv --all -n "$NAMESPACE" 2>/dev/null || true
    oc delete installplan --all -n "$NAMESPACE" 2>/dev/null || true
    oc delete catalogsource "$STAGED_CATALOG_NAME" -n openshift-marketplace --ignore-not-found 2>/dev/null || true
    oc delete operatorgroup cert-manager-operator -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    # Wait for operand pods to terminate
    local counter=0
    while [[ $counter -lt 60 ]]; do
        local pods
        pods=$(oc get pods -n "$CERT_MANAGER_NS" --no-headers 2>/dev/null | wc -l)
        if [[ "$pods" -eq 0 ]]; then break; fi
        sleep 5
        counter=$((counter + 5))
    done
}

# Main execution
log_info "Starting cert-manager upgrade-from-prod test"
log_info "STAGED_INDEX_IMAGE: ${STAGED_INDEX_IMAGE}"
log_info "UPGRADE_CHANNEL: ${UPGRADE_CHANNEL}"
log_info "OPERATOR_PACKAGE: ${OPERATOR_PACKAGE}"

setup_registry_auth

TARGET_VERSION=$(get_target_version)
log_info "Target version: ${TARGET_VERSION}"

mapfile -t FROM_VERSIONS < <(discover_upgrade_paths)
log_info "Upgrade paths to test: ${FROM_VERSIONS[*]}"

for from_ver in "${FROM_VERSIONS[@]}"; do
    log_info "============================================"
    log_info "Testing: v${from_ver} -> v${TARGET_VERSION}"
    log_info "============================================"

    install_from_prod "$from_ver"
    verify_operands
    swap_to_staged_catalog
    approve_upgrade
    verify_operands
    smoke_test
    cleanup
done

log_info "============================================"
log_info "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
log_info "============================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "UPGRADE TESTS FAILED"
    exit 1
fi
echo "ALL UPGRADE TESTS PASSED"
