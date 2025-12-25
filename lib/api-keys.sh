#!/bin/bash
# =============================================================================
# EZY Portal - API Key Management
# =============================================================================
# Shared functions for API key provisioning and management
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# -----------------------------------------------------------------------------
# API Key Provisioning
# -----------------------------------------------------------------------------

# Provision an API key via the backend API using deployment secret
# Usage: provision_api_key <service_name> [deployment_secret] [app_url]
# Returns: API key on stdout if successful, empty string otherwise
# Exit code: 0 on success, 1 on failure
provision_api_key() {
    local service_name="$1"
    local deployment_secret="${2:-${DEPLOYMENT_SECRET:-}}"
    local app_url="${3:-${APPLICATION_URL:-https://localhost}}"

    if [[ -z "$deployment_secret" ]]; then
        print_warning "DEPLOYMENT_SECRET not set, cannot auto-provision API key" >&2
        return 1
    fi

    print_info "Auto-provisioning API key for service: $service_name" >&2

    # Call the provision endpoint
    local response
    response=$(curl -s -k -X POST "${app_url}/api/service-api-keys/provision" \
        -H "X-Deployment-Secret: ${deployment_secret}" \
        -H "Content-Type: application/json" \
        -d "{\"serviceName\": \"${service_name}\"}" \
        --connect-timeout 10 \
        --max-time 30 2>&1)

    local curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        print_warning "Failed to connect to portal API: curl exit code $curl_exit" >&2
        return 1
    fi

    # Check for error responses
    if echo "$response" | grep -q '"message".*"Invalid deployment secret"'; then
        print_error "Invalid deployment secret" >&2
        return 1
    fi

    if echo "$response" | grep -q '"message".*"not configured"'; then
        print_warning "Deployment secret not configured on server" >&2
        return 1
    fi

    # Extract API key from response (only present if isNewKey=true)
    local api_key
    api_key=$(echo "$response" | grep -o '"apiKey"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"apiKey"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

    local is_new_key
    is_new_key=$(echo "$response" | grep -o '"isNewKey"[[:space:]]*:[[:space:]]*[a-z]*' | sed 's/"isNewKey"[[:space:]]*:[[:space:]]*//')

    if [[ "$is_new_key" == "true" ]] && [[ -n "$api_key" ]]; then
        print_success "API key provisioned successfully" >&2
        echo "$api_key"
        return 0
    elif [[ "$is_new_key" == "false" ]]; then
        print_info "API key already exists for this service" >&2
        # Return empty - caller should check portal.env or use existing
        return 0
    else
        print_warning "Unexpected response from provision API" >&2
        log_info "Provision response: $response" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# API Key Storage
# -----------------------------------------------------------------------------

# Save an API key to portal.env
# Usage: save_api_key_to_env <env_var_name> <api_key> [config_file]
save_api_key_to_env() {
    local env_var_name="$1"
    local api_key="$2"
    local config_file="${3:-${DEPLOY_ROOT}/portal.env}"

    if [[ -z "$api_key" ]]; then
        return 1
    fi

    # Update or add the API key in config file
    if grep -q "^${env_var_name}=" "$config_file" 2>/dev/null; then
        sed -i "s|^${env_var_name}=.*|${env_var_name}=${api_key}|" "$config_file"
    else
        echo "${env_var_name}=${api_key}" >> "$config_file"
    fi

    print_success "API key saved to $(basename "$config_file") as ${env_var_name}"
    return 0
}

# Get existing API key from portal.env
# Usage: get_existing_api_key <env_var_name> [config_file]
# Returns: API key value or empty string
get_existing_api_key() {
    local env_var_name="$1"
    local config_file="${2:-${DEPLOY_ROOT}/portal.env}"

    grep "^${env_var_name}=" "$config_file" 2>/dev/null | cut -d= -f2
}

# -----------------------------------------------------------------------------
# High-Level API Key Management
# -----------------------------------------------------------------------------

# Get or provision an API key for a service
# Usage: get_or_provision_api_key <service_name> <env_var_name> [explicit_key] [config_file]
# Returns: 0 on success (key available), 1 on failure (key not available)
get_or_provision_api_key() {
    local service_name="$1"
    local env_var_name="$2"
    local explicit_key="${3:-}"
    local config_file="${4:-${DEPLOY_ROOT}/portal.env}"

    # Priority 1: Use explicitly provided API key
    if [[ -n "$explicit_key" ]]; then
        save_api_key_to_env "$env_var_name" "$explicit_key" "$config_file"
        return 0
    fi

    # Priority 2: Check if already set in env file
    local existing
    existing=$(get_existing_api_key "$env_var_name" "$config_file")
    if [[ -n "$existing" ]]; then
        print_info "Using existing API key from $(basename "$config_file")"
        return 0
    fi

    # Priority 3: Auto-provision via deployment secret
    print_info "No API key provided, attempting auto-provision..."

    local deployment_secret
    deployment_secret=$(get_existing_api_key "DEPLOYMENT_SECRET" "$config_file")

    local app_url
    app_url=$(get_existing_api_key "APPLICATION_URL" "$config_file")
    app_url="${app_url:-https://localhost}"

    local provisioned_key
    provisioned_key=$(provision_api_key "$service_name" "$deployment_secret" "$app_url")
    local provision_result=$?

    if [[ $provision_result -eq 0 ]] && [[ -n "$provisioned_key" ]]; then
        # Save the newly provisioned key
        save_api_key_to_env "$env_var_name" "$provisioned_key" "$config_file"
        print_success "Auto-provisioned API key saved"
        return 0
    elif [[ $provision_result -eq 0 ]]; then
        # Key exists on server but we don't have it locally - check again
        existing=$(get_existing_api_key "$env_var_name" "$config_file")
        if [[ -n "$existing" ]]; then
            print_info "Using existing API key from $(basename "$config_file")"
            return 0
        fi
        print_warning "API key exists on server but not in $(basename "$config_file")"
        print_info "Please retrieve it from Portal Admin -> API Keys"
        return 1
    fi

    # Auto-provision failed
    print_error "API key is required for service '$service_name'"
    print_info "Options:"
    print_info "  1. Provide --api-key <key> argument"
    print_info "  2. Generate in Portal Admin -> API Keys"
    print_info "  3. Ensure DEPLOYMENT_SECRET is set for auto-provisioning"
    return 1
}

# -----------------------------------------------------------------------------
# Module-specific helpers
# -----------------------------------------------------------------------------

# Get the standard env var name for a built-in module
# Usage: get_module_api_key_var <module_name>
# Returns: Env var name (e.g., ITEMS_API_KEY for items)
get_module_api_key_var() {
    local module="$1"
    case "$module" in
        items) echo "ITEMS_API_KEY" ;;
        bp) echo "BP_API_KEY" ;;
        prospects) echo "PROSPECTS_API_KEY" ;;
        *) echo "$(echo "${module}_API_KEY" | tr '[:lower:]-' '[:upper:]_')" ;;
    esac
}
