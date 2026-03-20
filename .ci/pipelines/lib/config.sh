#!/usr/bin/env bash

# Configuration management utilities for CI pipelines
# Handles ConfigMap creation, dynamic plugins, and app configuration
# Dependencies: oc, yq, jq, lib/log.sh, lib/common.sh

# Prevent re-sourcing
if [[ -n "${CONFIG_LIB_SOURCED:-}" ]]; then
  return 0
fi
readonly CONFIG_LIB_SOURCED=1

# shellcheck source=.ci/pipelines/lib/log.sh
source "${DIR}/lib/log.sh"
# shellcheck source=.ci/pipelines/lib/common.sh
source "${DIR}/lib/common.sh"

# ==============================================================================
# ConfigMap Operations
# ==============================================================================

# Create app-config-rhdh ConfigMap from a configuration file
# Args:
#   $1 - config_file: Path to the app configuration file
#   $2 - namespace: Target namespace for the ConfigMap
# Returns:
#   0 - Success
config::create_app_config_map() {
  local config_file=$1
  local namespace=$2

  if [[ -z "$config_file" || -z "$namespace" ]]; then
    log::error "Missing required parameters"
    log::info "Usage: config::create_app_config_map <config_file> <namespace>"
    return 1
  fi

  oc create configmap app-config-rhdh \
    --from-file="app-config-rhdh.yaml"="$config_file" \
    --namespace="$namespace" \
    --dry-run=client -o yaml | oc apply -f -
  return $?
}

# Select the appropriate config map file based on project type
# Args:
#   $1 - project: The project/namespace name
#   $2 - dir: Base directory for config files
# Returns:
#   Prints the path to the appropriate config file
config::select_config_map_file() {
  local project=$1
  local dir=$2

  if [[ -z "$project" || -z "$dir" ]]; then
    log::error "Missing required parameters"
    log::info "Usage: config::select_config_map_file <project> <dir>"
    return 1
  fi

  if [[ "${project}" == *rbac* ]]; then
    echo "$dir/resources/config_map/app-config-rhdh-rbac.yaml"
  else
    echo "$dir/resources/config_map/app-config-rhdh.yaml"
  fi
  return 0
}

# ==============================================================================
# Dynamic Plugins Configuration
# ==============================================================================

# Create dynamic plugins ConfigMap from a values file
# Args:
#   $1 - base_file: Path to the values file containing plugin configuration
#   $2 - output_file: Path for the generated ConfigMap YAML
# Returns:
#   0 - Success
config::create_dynamic_plugins_config() {
  local base_file=$1
  local output_file=$2

  if [[ -z "$base_file" || -z "$output_file" ]]; then
    log::error "Missing required parameters"
    log::info "Usage: config::create_dynamic_plugins_config <base_file> <output_file>"
    return 1
  fi

  cat > "${output_file}" << 'EOF'
kind: ConfigMap
apiVersion: v1
metadata:
  name: dynamic-plugins
data:
  dynamic-plugins.yaml: |
EOF
  yq '.global.dynamic' "${base_file}" | sed -e 's/^/    /' >> "${output_file}"
  return $?
}

# Remove orchestrator-related dynamic plugin entries from merged Helm values (OSD-GCP operator).
# Orchestrator is not exercised on OSD-GCP; any remaining oci orchestrator rows stay disabled.
# Args:
#   $1 - values_file: Path to merged values YAML to edit in place
# Returns:
#   0 - Success
config::strip_orchestrator_plugin_entries_for_osd_gcp() {
  local values_file=$1
  local count_disabled

  if [[ -z "$values_file" ]]; then
    log::error "Missing values file path"
    return 1
  fi

  # yq rejects if/then/else inside map(); use per-element assignment (same intent as orchestrator.sh).
  yq eval -i '(.global.dynamic.plugins[]? | select((.package | tostring | downcase | contains("orchestrator")))).disabled = true' "${values_file}" || return 1
  count_disabled=$(yq e '[.global.dynamic.plugins[] | select(.package | tostring | downcase | contains("orchestrator"))] | length' "${values_file}" 2> /dev/null || echo 0)
  log::info "OSD-GCP: disabled ${count_disabled} orchestrator-related plugin(s)"

  return 0
}

# OSD-GCP shared CI clusters cannot reliably reach ghcr.io (skopeo timeouts during
# install-dynamic-plugins). Clear chart includes and drop GHCR OCI plugin rows so the init container
# only resolves quay.io, registry.access.redhat.com, and bundled dist paths.
# Also drop every {{inherit}} row: with CATALOG_INDEX_IMAGE unset on OSD-GCP operator CR, includes are
# empty and no catalog merge runs; {{inherit}} would have no base to resolve.
# Args:
#   $1 - values_file: merged Helm values to edit in place
# Returns:
#   0 - Success
config::strip_ghcr_dynamic_plugins_for_osd_gcp() {
  local values_file=$1
  local count_before count_after

  if [[ -z "${values_file}" ]]; then
    log::error "Missing values file path"
    return 1
  fi

  count_before=$(yq e '.global.dynamic.plugins | length' "${values_file}" 2> /dev/null || echo 0)
  yq -i '.global.dynamic.includes = []' "${values_file}" || return 1
  # Keep only plugins with a non-empty package that does not reference ghcr.io or {{inherit}}.
  yq -i '(.global.dynamic.plugins // []) |= map(select(
    (.package != null) and
    ((.package | tostring | length) > 0) and
    ((.package | tostring | downcase | contains("ghcr.io")) | not) and
    ((.package | tostring | contains("inherit")) | not)
  ))' "${values_file}" || return 1
  count_after=$(yq e '.global.dynamic.plugins | length' "${values_file}" 2> /dev/null || echo 0)
  log::info "OSD-GCP: cleared dynamic plugin includes; removed GHCR OCI rows ($((count_before - count_after)) removed, $count_after plugins remain)"

  if yq e '.global.dynamic.plugins[]?.package' "${values_file}" 2> /dev/null | grep -qi ghcr; then
    log::error "OSD-GCP: ghcr.io plugin entries still present after strip"
    return 1
  fi
  return 0
}

# Merge pipeline dynamic-plugins into the operator's backstage-dynamic-plugins-* ConfigMap (OSD-GCP).
# The init container reads the operator CM; defaults include oci {{inherit}} rows that cannot resolve
# when includes are empty. Strip ghcr + inherit from the operator copy, merge with CI ConfigMap
# dynamic-plugins (custom last wins per package), patch operator CM, restart Backstage.
# Args:
#   $1 - namespace
#   $2 - backstage Deployment name (e.g. backstage-rhdh)
# Returns:
#   0 - Success
config::merge_osd_gcp_operator_dynamic_plugins() {
  local namespace=$1
  local deployment_name=$2
  local operator_cm operator_yaml custom_yaml
  local op_raw op_stripped cust merged

  if [[ -z "${namespace}" || -z "${deployment_name}" ]]; then
    log::error "Usage: config::merge_osd_gcp_operator_dynamic_plugins <namespace> <deployment_name>"
    return 1
  fi

  if ! common::poll_until \
    "oc get cm -n ${namespace} --no-headers 2>/dev/null | grep -q backstage-dynamic-plugins-" \
    60 5 "operator backstage-dynamic-plugins ConfigMap in ${namespace}"; then
    return 1
  fi

  operator_cm=$(oc get cm -n "$namespace" --no-headers 2>/dev/null | awk '/backstage-dynamic-plugins-/{print $1; exit}')
  if [[ -z "${operator_cm}" ]]; then
    log::error "OSD-GCP: could not resolve backstage-dynamic-plugins ConfigMap in ${namespace}"
    return 1
  fi
  log::info "OSD-GCP: merging into operator ConfigMap ${operator_cm}"

  operator_yaml=$(oc get cm "$operator_cm" -n "$namespace" -o jsonpath='{.data.dynamic-plugins\.yaml}')
  custom_yaml=$(oc get cm "dynamic-plugins" -n "$namespace" -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || echo "")

  if [[ -z "${operator_yaml}" ]]; then
    log::error "OSD-GCP: ${operator_cm} has empty dynamic-plugins.yaml"
    return 1
  fi
  if [[ -z "${custom_yaml}" ]]; then
    log::error "OSD-GCP: ConfigMap dynamic-plugins missing or empty in ${namespace}"
    return 1
  fi

  op_raw=$(mktemp)
  op_stripped=$(mktemp)
  cust=$(mktemp)
  merged=$(mktemp)
  printf '%s\n' "$operator_yaml" > "$op_raw"
  printf '%s\n' "$custom_yaml" > "$cust"

  yq eval '
    .includes = [] |
    .plugins = (.plugins // [] | map(select(
      (.package != null) and
      ((.package | tostring | length) > 0) and
      ((.package | tostring | downcase | contains("ghcr.io")) | not) and
      ((.package | tostring | contains("inherit")) | not)
    )))
  ' "$op_raw" > "$op_stripped" || {
    rm -f "$op_raw" "$op_stripped" "$cust" "$merged"
    return 1
  }

  yq eval-all '
    select(fileIndex == 0) as $op |
    select(fileIndex == 1) as $cust |
    {
      "includes": [],
      "plugins": (($op.plugins // []) + ($cust.plugins // [])) | group_by(.package) | map(.[-1])
    }
  ' "$op_stripped" "$cust" > "$merged" || {
    rm -f "$op_raw" "$op_stripped" "$cust" "$merged"
    return 1
  }

  oc patch cm "$operator_cm" -n "$namespace" --type merge -p \
    "{\"data\":{\"dynamic-plugins.yaml\":$(jq -Rs . < "$merged")}}" || {
    rm -f "$op_raw" "$op_stripped" "$cust" "$merged"
    return 1
  }
  rm -f "$op_raw" "$op_stripped" "$cust" "$merged"

  log::info "OSD-GCP: restarting deployment/${deployment_name} to pick up merged plugins"
  oc rollout restart "deployment/${deployment_name}" -n "$namespace" || return 1
  return 0
}

# ==============================================================================
# Operator Configuration
# ==============================================================================

# Create conditional policies file for RBAC operator deployment
# Args:
#   $1 - destination_file: Path for the generated policies file
# Returns:
#   0 - Success
config::create_conditional_policies_operator() {
  local destination_file=$1

  if [[ -z "$destination_file" ]]; then
    log::error "Missing required parameter: destination_file"
    log::info "Usage: config::create_conditional_policies_operator <destination_file>"
    return 1
  fi

  yq '.upstream.backstage.initContainers[0].command[2]' "${DIR}/value_files/values_showcase-rbac.yaml" \
    | head -n -4 \
    | tail -n +2 > "$destination_file"
  common::sed_inplace 's/\\\$/\$/g' "$destination_file"
  return $?
}

# Prepare app configuration for operator deployment with RBAC
# Args:
#   $1 - config_file: Path to the app configuration file to modify
# Returns:
#   0 - Success
config::prepare_operator_app_config() {
  local config_file=$1

  if [[ -z "$config_file" ]]; then
    log::error "Missing required parameter: config_file"
    log::info "Usage: config::prepare_operator_app_config <config_file>"
    return 1
  fi

  yq e -i '.permission.rbac.conditionalPoliciesFile = "./rbac/conditional-policies.yaml"' "${config_file}"
  return $?
}
