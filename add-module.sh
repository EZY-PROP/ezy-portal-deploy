#!/bin/bash
# =============================================================================
# EZY Portal - Add Module Script
# =============================================================================
# Hot-add a micro-frontend module to a running portal installation.
#
# Usage:
#   ./add-module.sh items                     # Add items module (auto-provision key)
#   ./add-module.sh bp                        # Add bp module (requires items)
#   ./add-module.sh prospects                 # Add prospects module (requires bp)
#   ./add-module.sh items --api-key <key>     # Use explicit API key
#   ./add-module.sh items --local             # Use local Docker image
#
# API Key Provisioning:
#   If --api-key is not provided, the script will auto-provision an API key
#   using DEPLOYMENT_SECRET (generated during install.sh).
#
# The portal must be running before adding modules.
# =============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"

# Source library scripts
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/checks.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/docker.sh"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MODULE=""
API_KEY=""
USE_LOCAL_IMAGES=false
VERSION="${VERSION:-latest}"

# Module dependencies
declare -A MODULE_DEPENDENCIES=(
    ["items"]=""
    ["bp"]="items"
    ["prospects"]="bp"
)

# API key variable names
declare -A MODULE_API_KEY_VARS=(
    ["items"]="ITEMS_API_KEY"
    ["bp"]="BP_API_KEY"
    ["prospects"]="PROSPECTS_API_KEY"
)

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    MODULE="$1"
    shift

    # Validate module name
    if [[ ! "$MODULE" =~ ^(items|bp|prospects)$ ]]; then
        print_error "Invalid module: $MODULE"
        print_info "Available modules: items, bp, prospects"
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --local)
                USE_LOCAL_IMAGES=true
                shift
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    export USE_LOCAL_IMAGES
}

show_help() {
    echo "EZY Portal - Add Module"
    echo ""
    echo "Usage: ./add-module.sh <module> [OPTIONS]"
    echo ""
    echo "Modules:"
    echo "  items       Items micro-frontend (base module)"
    echo "  bp          Business Partners (requires: items)"
    echo "  prospects   Prospects (requires: bp, items)"
    echo ""
    echo "Options:"
    echo "  --api-key KEY    API key for the module (optional - auto-provisioned if not provided)"
    echo "  --local          Use local Docker image instead of GHCR"
    echo "  --version VER    Image version tag (default: latest)"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "API Key Provisioning:"
    echo "  If --api-key is not provided, the script will:"
    echo "    1. Use existing key from portal.env (if present)"
    echo "    2. Auto-provision via DEPLOYMENT_SECRET (if configured)"
    echo "    3. Prompt for manual key generation"
    echo ""
    echo "Examples:"
    echo "  ./add-module.sh items                      # Auto-provision API key"
    echo "  ./add-module.sh items --api-key abc123     # Use explicit API key"
    echo "  ./add-module.sh bp --local                 # Local image, auto-provision key"
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
check_portal_running() {
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="$project_name"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_error "Portal is not running"
        print_info "Start the portal first with: ./install.sh"
        return 1
    fi

    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

    if [[ "$health" != "healthy" ]]; then
        print_warning "Portal is running but not healthy (status: $health)"
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    print_success "Portal is running and healthy"
    return 0
}

check_dependencies() {
    local module="$1"
    local deps="${MODULE_DEPENDENCIES[$module]}"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    print_info "Checking dependencies for $module..."

    IFS=',' read -ra dep_array <<< "$deps"
    for dep in "${dep_array[@]}"; do
        dep=$(echo "$dep" | xargs)
        local container="${project_name}-${dep}"

        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_error "Required module '$dep' is not running"
            print_info "Add it first with: ./add-module.sh $dep --api-key <key>"
            return 1
        fi

        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        if [[ "$health" == "healthy" ]]; then
            print_success "Dependency '$dep' is running and healthy"
        else
            print_warning "Dependency '$dep' is running but not healthy"
        fi
    done

    return 0
}

check_module_not_running() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Module '$module' is already running"
        if confirm "Recreate the container?" "n"; then
            return 0
        fi
        exit 0
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

# Provision an API key via the backend API using deployment secret
provision_api_key() {
    local module="$1"
    local deployment_secret="${DEPLOYMENT_SECRET:-}"
    local app_url="${APPLICATION_URL:-https://localhost}"

    if [[ -z "$deployment_secret" ]]; then
        print_warning "DEPLOYMENT_SECRET not set, cannot auto-provision API key" >&2
        return 1
    fi

    print_info "Auto-provisioning API key for module: $module" >&2

    # Call the provision endpoint
    local response
    response=$(curl -s -k -X POST "${app_url}/api/service-api-keys/provision" \
        -H "X-Deployment-Secret: ${deployment_secret}" \
        -H "Content-Type: application/json" \
        -d "{\"serviceName\": \"${module}\"}" \
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
        print_info "API key already exists for this module" >&2
        # Return empty - caller should check portal.env or use existing
        return 0
    else
        print_warning "Unexpected response from provision API" >&2
        log_info "Provision response: $response" >&2
        return 1
    fi
}

save_api_key() {
    local module="$1"
    local api_key="$2"
    local var_name="${MODULE_API_KEY_VARS[$module]}"

    # Priority 1: Use explicitly provided API key
    if [[ -n "$api_key" ]]; then
        # Update or add the API key in portal.env
        if grep -q "^${var_name}=" "$DEPLOY_ROOT/portal.env" 2>/dev/null; then
            sed -i "s|^${var_name}=.*|${var_name}=${api_key}|" "$DEPLOY_ROOT/portal.env"
        else
            echo "${var_name}=${api_key}" >> "$DEPLOY_ROOT/portal.env"
        fi
        print_success "API key saved to portal.env"
        return 0
    fi

    # Priority 2: Check if already set in env file
    local existing
    existing=$(grep "^${var_name}=" "$DEPLOY_ROOT/portal.env" 2>/dev/null | cut -d= -f2)
    if [[ -n "$existing" ]]; then
        print_info "Using existing API key from portal.env"
        return 0
    fi

    # Priority 3: Auto-provision via deployment secret
    print_info "No API key provided, attempting auto-provision..."
    local provisioned_key
    provisioned_key=$(provision_api_key "$module")
    local provision_result=$?

    if [[ $provision_result -eq 0 ]] && [[ -n "$provisioned_key" ]]; then
        # Save the newly provisioned key
        echo "${var_name}=${provisioned_key}" >> "$DEPLOY_ROOT/portal.env"
        print_success "Auto-provisioned API key saved to portal.env"
        return 0
    elif [[ $provision_result -eq 0 ]]; then
        # Key exists on server but we don't have it locally - check again
        existing=$(grep "^${var_name}=" "$DEPLOY_ROOT/portal.env" 2>/dev/null | cut -d= -f2)
        if [[ -n "$existing" ]]; then
            print_info "Using existing API key from portal.env"
            return 0
        fi
        print_warning "API key exists on server but not in portal.env"
        print_info "Please retrieve it from Portal Admin -> API Keys"
        return 1
    fi

    # Auto-provision failed, fall back to manual instructions
    print_error "API key is required for module '$module'"
    print_info "Options:"
    print_info "  1. Run with --api-key: ./add-module.sh $module --api-key <key>"
    print_info "  2. Generate in Portal Admin -> API Keys"
    print_info "  3. Ensure DEPLOYMENT_SECRET is set for auto-provisioning"
    return 1
}

start_module() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Load config to get infrastructure mode
    load_config "$DEPLOY_ROOT/portal.env"

    local infra_mode="${INFRASTRUCTURE_MODE:-full}"

    # Build compose file arguments
    local base_compose
    base_compose=$(get_compose_file "$infra_mode")

    local module_compose="$DEPLOY_ROOT/docker/docker-compose.module-${module}.yml"

    if [[ ! -f "$module_compose" ]]; then
        print_error "Module compose file not found: $module_compose"
        return 1
    fi

    # Include dependency compose files in order
    local compose_args="-f $base_compose"
    local ordered_modules=("items" "bp" "prospects")

    for m in "${ordered_modules[@]}"; do
        local m_compose="$DEPLOY_ROOT/docker/docker-compose.module-${m}.yml"
        if [[ -f "$m_compose" ]]; then
            # Include if it's the target module or a running dependency
            local container="${project_name}-${m}"
            if [[ "$m" == "$module" ]] || docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                compose_args="$compose_args -f $m_compose"
            fi
        fi
        [[ "$m" == "$module" ]] && break
    done

    # Set image environment variable
    local image
    image=$(get_module_image "$module")
    local var_name
    var_name="$(echo "${module}_IMAGE" | tr '[:lower:]' '[:upper:]')"
    export "$var_name=$image"

    print_info "Starting module: $module"
    print_info "Image: $image:$VERSION"

    # Use --no-recreate to avoid touching existing containers (portal, infra)
    local cmd="docker compose $compose_args --env-file $DEPLOY_ROOT/portal.env up -d --no-recreate $module"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Module '$module' started"
        return 0
    else
        print_error "Failed to start module '$module'"
        return 1
    fi
}

wait_for_module_healthy() {
    local module="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-${module}"
    local timeout=120

    print_info "Waiting for $module to be healthy..."

    if wait_for_healthy "$container" "$timeout"; then
        return 0
    else
        print_warning "Module did not become healthy within ${timeout}s"
        print_info "Check logs: docker logs $container"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Adding Module: $MODULE"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    else
        print_error "portal.env not found. Run ./install.sh first."
        exit 1
    fi

    # Pre-flight checks
    check_portal_running || exit 1
    check_dependencies "$MODULE" || exit 1
    check_module_not_running "$MODULE"

    # Save API key
    save_api_key "$MODULE" "$API_KEY" || exit 1

    # Pull/verify image
    print_section "Preparing Image"
    if ! docker_pull_image "$VERSION" "$MODULE"; then
        exit 1
    fi

    # Start the module
    print_section "Starting Module"
    if ! start_module "$MODULE"; then
        exit 1
    fi

    # Wait for healthy
    wait_for_module_healthy "$MODULE" || true

    # Success
    local app_url="${APPLICATION_URL:-https://localhost}"
    echo ""
    print_success "Module '$MODULE' added successfully!"
    echo ""
    echo "  Module URL: $app_url/mfe/$MODULE/"
    echo "  Container:  ${PROJECT_NAME:-ezy-portal}-$MODULE"
    echo "  Logs:       docker logs ${PROJECT_NAME:-ezy-portal}-$MODULE"
    echo ""

    log_info "Module added: $MODULE"
}

main "$@"
