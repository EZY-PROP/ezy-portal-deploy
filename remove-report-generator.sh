#!/bin/bash
# =============================================================================
# EZY Portal - Remove Report Generator Script
# =============================================================================
# Remove the Report Generator service(s).
#
# Usage:
#   ./remove-report-generator.sh api              # Remove API only
#   ./remove-report-generator.sh service          # Remove scheduler service only
#   ./remove-report-generator.sh all              # Remove both
#   ./remove-report-generator.sh all --force      # Remove without confirmation
#   ./remove-report-generator.sh all --purge      # Also remove data directories
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

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SERVICE_TYPE=""
FORCE=false
PURGE=false

# -----------------------------------------------------------------------------
# Parse Arguments
# -----------------------------------------------------------------------------
parse_arguments() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    SERVICE_TYPE="$1"
    shift

    # Validate service type
    if [[ ! "$SERVICE_TYPE" =~ ^(api|service|all)$ ]]; then
        print_error "Invalid service type: $SERVICE_TYPE"
        print_info "Available types: api, service, all"
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --force|-f)
                FORCE=true
                shift
                ;;
            --purge)
                PURGE=true
                shift
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
}

show_help() {
    echo "EZY Portal - Remove Report Generator"
    echo ""
    echo "Usage: ./remove-report-generator.sh <service-type> [OPTIONS]"
    echo ""
    echo "Service Types:"
    echo "  api       Remove REST API service"
    echo "  service   Remove background scheduler service"
    echo "  all       Remove both services"
    echo ""
    echo "Options:"
    echo "  --force, -f      Remove without confirmation"
    echo "  --purge          Also remove data directories (output, logs)"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./remove-report-generator.sh api               # Remove API only"
    echo "  ./remove-report-generator.sh all               # Remove both (with confirmation)"
    echo "  ./remove-report-generator.sh all --force       # Remove without confirmation"
    echo "  ./remove-report-generator.sh all --purge       # Remove and clean up data"
    echo ""
    echo "Note: Reports directory is never removed. Clean up manually if needed."
}

# -----------------------------------------------------------------------------
# Remove Services
# -----------------------------------------------------------------------------
stop_service() {
    local service_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-report-generator-${service_name}"
    local compose_file="$DEPLOY_ROOT/docker/docker-compose.report-generator-${service_name}.yml"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        print_info "Report generator $service_name is not running"
        return 0
    fi

    print_info "Stopping report-generator-${service_name}..."

    # Stop and remove container directly
    docker stop "$container" 2>/dev/null || true
    docker rm "$container" 2>/dev/null || true

    print_success "Report generator $service_name removed"
}

purge_data() {
    local base_dir="$DEPLOY_ROOT/report-generator"

    print_warning "Purging data directories..."

    # Remove output and logs but keep reports
    rm -rf "$base_dir/output"/*
    rm -rf "$base_dir/logs"/*

    # Recreate .gitkeep files
    mkdir -p "$base_dir/output"
    mkdir -p "$base_dir/logs/api"
    mkdir -p "$base_dir/logs/service"
    touch "$base_dir/output/.gitkeep"
    touch "$base_dir/logs/api/.gitkeep"
    touch "$base_dir/logs/service/.gitkeep"

    print_success "Data directories purged (reports preserved)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Removing Report Generator: $SERVICE_TYPE"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    fi

    # Confirm removal
    if [[ "$FORCE" != "true" ]]; then
        local confirm_msg="Remove report generator ($SERVICE_TYPE)?"
        if [[ "$PURGE" == "true" ]]; then
            confirm_msg="Remove report generator ($SERVICE_TYPE) and purge data?"
        fi
        if ! confirm "$confirm_msg" "n"; then
            print_info "Cancelled"
            exit 0
        fi
    fi

    # Determine which services to remove
    local services=()
    case "$SERVICE_TYPE" in
        api)
            services=("api")
            ;;
        service)
            services=("service")
            ;;
        all)
            services=("api" "service")
            ;;
    esac

    # Stop services
    print_section "Stopping Services"
    for svc in "${services[@]}"; do
        stop_service "$svc"
    done

    # Purge data if requested
    if [[ "$PURGE" == "true" ]]; then
        print_section "Purging Data"
        purge_data
    fi

    # Success output
    echo ""
    print_section "Removal Complete!"
    print_success "Report Generator ($SERVICE_TYPE) removed successfully!"
    echo ""

    if [[ "$PURGE" != "true" ]]; then
        echo "Data directories preserved at: $DEPLOY_ROOT/report-generator/"
        echo "Use --purge to remove output and logs."
    fi
    echo ""

    log_info "Report Generator removed: $SERVICE_TYPE"
}

main "$@"
