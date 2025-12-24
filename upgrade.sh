#!/bin/bash
# =============================================================================
# EZY Portal Upgrade Script
# =============================================================================
# Safely upgrades existing EZY Portal installation with backup and rollback
#
# Usage:
#   ./upgrade.sh                        # Upgrade to latest
#   ./upgrade.sh --version 1.0.1        # Upgrade to specific version
#   ./upgrade.sh --rollback             # Rollback to previous version
#   ./upgrade.sh --skip-backup          # Skip backup (not recommended)
#
# Features:
#   - Automatic backup before upgrade
#   - Health check validation
#   - Automatic rollback on failure
#   - Version comparison
#
# Environment Variables:
#   GITHUB_PAT          - GitHub Personal Access Token (required)
#   VERSION             - Target version (default: latest)
#
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
source "$SCRIPT_DIR/lib/ssl.sh"
source "$SCRIPT_DIR/lib/backup.sh"

# -----------------------------------------------------------------------------
# Default Values
# -----------------------------------------------------------------------------
VERSION="${VERSION:-latest}"
PROJECT_NAME="${PROJECT_NAME:-ezy-portal}"
SKIP_BACKUP=false
DO_ROLLBACK=false
FORCE=false

# -----------------------------------------------------------------------------
# Parse Command Line Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --rollback)
                DO_ROLLBACK=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "EZY Portal Upgrade Script"
    echo ""
    echo "Usage: ./upgrade.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version VERSION     Upgrade to specific version (default: latest)"
    echo "  --skip-backup         Skip backup before upgrade (not recommended)"
    echo "  --rollback            Rollback to previous version from backup"
    echo "  --force               Force upgrade even if same version"
    echo "  --help, -h            Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Upgrade to latest"
    echo "  ./upgrade.sh"
    echo ""
    echo "  # Upgrade to specific version"
    echo "  ./upgrade.sh --version 1.0.2"
    echo ""
    echo "  # Rollback to previous version"
    echo "  ./upgrade.sh --rollback"
}

# -----------------------------------------------------------------------------
# Upgrade Steps
# -----------------------------------------------------------------------------

step_validate_installation() {
    print_section "Step 1: Validating Installation"

    if ! check_existing_installation; then
        print_error "No existing installation found"
        print_info "Run ./install.sh first to install the portal"
        exit 1
    fi

    print_success "Existing installation found"

    # Load configuration
    load_config "$DEPLOY_ROOT/portal.env"

    # Get current version
    CURRENT_VERSION=$(get_current_portal_version)
    print_info "Current version: $CURRENT_VERSION"
    print_info "Target version: $VERSION"

    # Detect infrastructure mode
    INFRASTRUCTURE_MODE=$(detect_infrastructure_type)
    print_info "Infrastructure mode: $INFRASTRUCTURE_MODE"
}

step_check_prerequisites() {
    print_section "Step 2: Checking Prerequisites"

    # Check Docker
    if ! check_docker_installed || ! check_docker_running; then
        exit 1
    fi

    # Check GITHUB_PAT
    if ! check_github_pat; then
        exit 1
    fi

    # Login to GHCR
    if ! check_ghcr_login; then
        exit 1
    fi

    print_success "Prerequisites met"
}

step_compare_versions() {
    print_section "Step 3: Comparing Versions"

    if [[ "$CURRENT_VERSION" == "$VERSION" ]] && [[ "$FORCE" != true ]]; then
        print_info "Already running version $VERSION"

        if ! confirm "Force reinstall?" "n"; then
            print_info "Upgrade cancelled"
            exit 0
        fi
    elif [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
        print_warning "Forcing reinstall of version $VERSION"
    else
        print_info "Will upgrade from $CURRENT_VERSION to $VERSION"
    fi

    if ! confirm "Proceed with upgrade?" "y"; then
        print_info "Upgrade cancelled"
        exit 0
    fi
}

step_create_backup() {
    print_section "Step 4: Creating Backup"

    if [[ "$SKIP_BACKUP" == true ]]; then
        print_warning "Skipping backup as requested"
        print_warning "You will not be able to rollback if upgrade fails!"

        if ! confirm "Continue without backup?" "n"; then
            exit 1
        fi
        return 0
    fi

    BACKUP_PATH=$(create_full_backup "pre-upgrade-to-$VERSION")

    if [[ -z "$BACKUP_PATH" ]] || [[ ! -d "$BACKUP_PATH" ]]; then
        print_error "Backup failed"

        if ! confirm "Continue without backup?" "n"; then
            exit 1
        fi
    else
        # Record rollback info
        record_rollback_info "$BACKUP_PATH" "$CURRENT_VERSION" "$VERSION"
        print_success "Backup created: $BACKUP_PATH"
    fi
}

step_pull_new_image() {
    print_section "Step 5: Pulling Images"

    print_info "Version: $VERSION"
    print_info "Modules: ${MODULES:-portal}"

    # Pull images for all configured modules
    if ! docker_pull_modules "$VERSION" "${MODULES:-portal}"; then
        print_error "Failed to pull images for version $VERSION"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_info "Backup is available for rollback: $BACKUP_PATH"
        fi
        exit 1
    fi
}

step_stop_services() {
    print_section "Step 6: Stopping Current Services"

    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Stop all module containers, keep infrastructure running
    print_info "Stopping module containers..."

    # Stop main portal
    docker stop "${project_name}" 2>/dev/null || true
    docker rm "${project_name}" 2>/dev/null || true

    # Stop module containers based on MODULES config
    IFS=',' read -ra module_array <<< "${MODULES:-portal}"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ "$module" != "portal" && -n "$module" ]]; then
            local container="${project_name}-${module}"
            print_info "Stopping $container..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        fi
    done

    print_success "Module containers stopped"
}

step_start_new_version() {
    print_section "Step 7: Starting New Version"

    # Update version in config
    save_config_value "VERSION" "$VERSION" "$DEPLOY_ROOT/portal.env"

    # Generate module image environment variables
    generate_module_image_vars "$VERSION" "${MODULES:-portal}"

    # Get compose files for all modules
    local compose_args
    compose_args=$(get_compose_files_for_modules "$INFRASTRUCTURE_MODE" "${MODULES:-portal}")

    print_info "Starting with compose files: $compose_args"

    # Start services using compose args directly
    local cmd="docker compose $compose_args --env-file $DEPLOY_ROOT/portal.env up -d"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Services started"
    else
        print_error "Failed to start new version"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_warning "Attempting automatic rollback..."
            do_rollback "$BACKUP_PATH"
        fi
        exit 1
    fi
}

step_verify_health() {
    print_section "Step 8: Verifying Health"

    local project_name="${PROJECT_NAME:-ezy-portal}"
    local timeout=180
    local failed=0

    # Check main portal
    if ! wait_for_healthy "$project_name" "$timeout"; then
        print_error "Portal did not become healthy"
        ((failed++))
    fi

    # Check module containers
    IFS=',' read -ra module_array <<< "${MODULES:-portal}"
    for module in "${module_array[@]}"; do
        module=$(echo "$module" | xargs)
        if [[ "$module" != "portal" && -n "$module" ]]; then
            local container="${project_name}-${module}"
            if ! wait_for_healthy "$container" 60; then
                print_error "$container did not become healthy"
                ((failed++))
            fi
        fi
    done

    if [[ $failed -gt 0 ]]; then
        print_error "$failed container(s) failed health check"

        if [[ -n "${BACKUP_PATH:-}" ]]; then
            print_warning "Attempting automatic rollback..."
            do_rollback "$BACKUP_PATH"
        fi
        exit 1
    fi

    print_success "All containers are healthy"
}

step_cleanup() {
    print_section "Step 9: Cleanup"

    # Clean up old images
    docker_cleanup_old_images 3

    # Clean up old backups
    cleanup_old_backups 5

    print_success "Cleanup complete"
}

do_rollback() {
    local backup_path="${1:-}"

    if [[ -z "$backup_path" ]]; then
        # Find the latest backup
        local latest
        latest=$(get_latest_backup)

        if [[ -z "$latest" ]]; then
            print_error "No backups available for rollback"
            exit 1
        fi

        backup_path="${BACKUP_DIR}/${latest}"
    fi

    print_section "Rolling Back"
    print_info "Using backup: $backup_path"

    # Get the version to rollback to
    local rollback_version="$CURRENT_VERSION"
    if [[ -f "$backup_path/rollback.json" ]]; then
        rollback_version=$(grep -o '"to_version"[^,]*' "$backup_path/rollback.json" | cut -d'"' -f4)
    fi

    print_info "Rolling back to version: $rollback_version"

    # Update version in config
    save_config_value "VERSION" "$rollback_version" "$DEPLOY_ROOT/portal.env"

    # Restart with old version
    local compose_file
    compose_file=$(get_compose_file "$INFRASTRUCTURE_MODE")

    docker_compose_down "$compose_file"
    docker_compose_up "$compose_file" "$DEPLOY_ROOT/portal.env"

    # Restore database if needed
    if [[ -f "$backup_path/database.sql" ]]; then
        print_info "Restoring database..."
        sleep 10  # Wait for postgres to start
        restore_database "$backup_path"
    fi

    # Wait for health
    local container="${PROJECT_NAME:-ezy-portal}"
    if wait_for_healthy "$container" 120; then
        print_success "Rollback completed successfully"
    else
        print_error "Rollback completed but portal is not healthy"
        print_info "Check logs: docker logs $container"
    fi
}

show_success() {
    local app_url="${APPLICATION_URL:-https://localhost}"

    print_section "Upgrade Complete!"

    echo ""
    print_success "EZY Portal upgraded to version $VERSION"
    echo ""
    echo "  Previous version: $CURRENT_VERSION"
    echo "  Current version:  $VERSION"
    echo ""
    echo "  Portal URL:       $app_url"
    echo ""

    if [[ -n "${BACKUP_PATH:-}" ]]; then
        echo "  Backup location:  $BACKUP_PATH"
        echo ""
        echo "  To rollback:      ./upgrade.sh --rollback"
    fi

    log_info "Upgrade completed: $CURRENT_VERSION -> $VERSION"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    init_logging
    log_info "Starting upgrade - Target version: $VERSION"

    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                    EZY Portal Upgrade                         ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    parse_arguments "$@"

    # Handle rollback mode
    if [[ "$DO_ROLLBACK" == true ]]; then
        step_validate_installation
        do_rollback
        exit 0
    fi

    # Normal upgrade flow
    step_validate_installation
    step_check_prerequisites
    step_compare_versions
    step_create_backup
    step_pull_new_image
    step_stop_services
    step_start_new_version
    step_verify_health
    step_cleanup
    show_success
}

# Run main function
main "$@"
