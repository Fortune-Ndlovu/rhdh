#!/usr/bin/env bash

# Configuration management utilities for CI pipelines
# Handles ConfigMap creation, dynamic plugins, and app configuration
# Dependencies: oc, yq, lib/log.sh, lib/common.sh

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
#   $3 - optional: "osd_gcp" to add orchestrator-base.yaml so catalog {{inherit}} has a base
# Returns:
#   0 - Success
config::create_dynamic_plugins_config() {
  local base_file=$1
  local output_file=$2
  local osd_gcp="${3:-}"

  if [[ -z "$base_file" || -z "$output_file" ]]; then
    log::error "Missing required parameters"
    log::info "Usage: config::create_dynamic_plugins_config <base_file> <output_file> [osd_gcp]"
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

  if [[ "${osd_gcp}" == "osd_gcp" ]]; then
    # Catalog (or operator default) may inject CATALOG_INDEX_IMAGE; provide bases for all
    # orchestrator-related plugins that use {{inherit}} so the installer does not fail.
    cat >> "${output_file}" << 'ORCHBASE'
  orchestrator-base.yaml: |
    plugins:
      - package: oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-orchestrator:1.10
        disabled: true
      - package: oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-orchestrator-backend:1.10
        disabled: true
      - package: oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-scaffolder-backend-module-orchestrator:1.10
        disabled: true
      - package: oci://registry.access.redhat.com/rhdh/red-hat-developer-hub-backstage-plugin-orchestrator-form-widgets:1.10
        disabled: true
ORCHBASE
    log::info "OSD-GCP: added orchestrator-base.yaml (4 plugins) to ConfigMap so catalog {{inherit}} has a base"
  fi
  return $?
}

# Set OSD-GCP dynamic includes so the catalog is loaded and orchestrator {{inherit}} finds a base.
# Call after strip_ghcr_dynamic_plugins_for_osd_gcp. Ensures includes list orchestrator-base.yaml
# first, then dynamic-plugins.default.yaml (replaced by script with catalog path when CATALOG_INDEX_IMAGE is set).
# Args:
#   $1 - dir: Pipeline DIR (unused, for future use)
#   $2 - values_file: Path to merged values YAML to edit in place
# Returns:
#   0 - Success
config::set_osd_gcp_dynamic_includes_for_catalog() {
  local values_file=$2
  if [[ -z "$values_file" ]]; then
    log::error "Missing values file path"
    return 1
  fi
  yq -i '.global.dynamic.includes = ["orchestrator-base.yaml", "dynamic-plugins.default.yaml"]' "${values_file}" || return 1
  log::info "OSD-GCP: set dynamic includes to [orchestrator-base.yaml, dynamic-plugins.default.yaml] for catalog"
  return 0
}

# Remove orchestrator-related dynamic plugin entries from merged Helm values (OSD-GCP operator).
# Disabled orchestrator packages still merge with the catalog index and duplicate GHCR overlay
# entries, causing install-dynamic-plugins InstallException (RHDH nightly OSD-GCP).
# Args:
#   $1 - values_file: Path to merged values YAML to edit in place
# Returns:
#   0 - Success
config::strip_orchestrator_plugin_entries_for_osd_gcp() {
  local values_file=$1
  local count_before count_after

  if [[ -z "$values_file" ]]; then
    log::error "Missing values file path"
    return 1
  fi

  count_before=$(yq e '.global.dynamic.plugins | length' "${values_file}" 2> /dev/null || echo 0)
  # yq-only filter preserves Helm template literals in package strings (e.g. {{ "{{" }}inherit{{ "}}" }}).
  # Do not round-trip through jq/json — that corrupts those strings and breaks install-dynamic-plugins.
  yq -i '(.global.dynamic.plugins // []) |= map(select((.package | tostring | downcase | contains("orchestrator") | not)))' "${values_file}" || return 1
  count_after=$(yq e '.global.dynamic.plugins | length' "${values_file}" 2> /dev/null || echo 0)
  log::info "OSD-GCP: removed $((count_before - count_after)) orchestrator-related plugin row(s) ($count_after remaining)"

  if yq e '.global.dynamic.plugins[]?.package' "${values_file}" 2> /dev/null | grep -qi orchestrator; then
    log::error "OSD-GCP: orchestrator plugin entries still present after strip"
    return 1
  fi
  return 0
}

# OSD-GCP shared CI clusters cannot reliably reach ghcr.io (skopeo timeouts during
# install-dynamic-plugins). Drop catalog/includes merge and all GHCR OCI plugin rows
# so the init container only resolves quay.io, registry.access.redhat.com, and bundled dist paths.
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
  # Keep only plugins with a non-empty package that does not reference ghcr.io. Dropping null/empty
  # package avoids install-dynamic-plugins crashes; dropping {{inherit}} refs avoids "no existing
  # plugin configuration found" when includes is empty.
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
