#!/bin/bash
# =============================================================================
# EZY Portal - Add Report Generator Script
# =============================================================================
# Install the optional Report Generator service(s) for PDF generation.
#
# Usage:
#   ./add-report-generator.sh api              # Install API only
#   ./add-report-generator.sh service          # Install scheduler service only
#   ./add-report-generator.sh all              # Install both API and service
#   ./add-report-generator.sh api --version 1.0.0   # Specific version
#
# The portal must be running before adding the report generator.
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
SERVICE_TYPE=""
REPORT_GENERATOR_VERSION="${REPORT_GENERATOR_VERSION:-latest}"

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
            --version)
                REPORT_GENERATOR_VERSION="$2"
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

    export REPORT_GENERATOR_VERSION
}

show_help() {
    echo "EZY Portal - Add Report Generator"
    echo ""
    echo "Usage: ./add-report-generator.sh <service-type> [OPTIONS]"
    echo ""
    echo "Service Types:"
    echo "  api       REST API for on-demand report generation"
    echo "  service   Background scheduler for scheduled reports"
    echo "  all       Install both API and scheduler service"
    echo ""
    echo "Options:"
    echo "  --version VER    Image version tag (default: latest)"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./add-report-generator.sh api                    # Install API only"
    echo "  ./add-report-generator.sh service                # Install scheduler only"
    echo "  ./add-report-generator.sh all                    # Install both"
    echo "  ./add-report-generator.sh api --version 1.0.0    # Specific version"
    echo ""
    echo "After installation, services are accessible via Docker network:"
    echo "  API:     http://report-generator-api:5127/api/reports/..."
    echo "  Health:  http://report-generator-api:5127/api/admin/health"
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

check_service_not_running() {
    local service_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-report-generator-${service_name}"

    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        print_warning "Report generator $service_name is already running"
        if confirm "Recreate the container?" "n"; then
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            return 0
        fi
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Directory Setup
# -----------------------------------------------------------------------------
ensure_directory_structure() {
    local base_dir="$DEPLOY_ROOT/report-generator"

    mkdir -p "$base_dir/reports"
    mkdir -p "$base_dir/output"
    mkdir -p "$base_dir/logs/api"
    mkdir -p "$base_dir/logs/service"

    # Create .gitkeep files if they don't exist
    [[ -f "$base_dir/reports/.gitkeep" ]] || touch "$base_dir/reports/.gitkeep"
    [[ -f "$base_dir/output/.gitkeep" ]] || touch "$base_dir/output/.gitkeep"
    [[ -f "$base_dir/logs/api/.gitkeep" ]] || touch "$base_dir/logs/api/.gitkeep"
    [[ -f "$base_dir/logs/service/.gitkeep" ]] || touch "$base_dir/logs/service/.gitkeep"

    print_success "Directory structure ready"
}

# -----------------------------------------------------------------------------
# Image Management
# -----------------------------------------------------------------------------
pull_image() {
    local service_name="$1"
    local ghcr_image="ghcr.io/ezy-prop/ezy-report-generator-${service_name}:${REPORT_GENERATOR_VERSION}"

    # Check if image already exists locally
    if docker image inspect "$ghcr_image" &>/dev/null; then
        print_success "Image found locally: $ghcr_image"
        return 0
    fi

    # Pull from registry
    print_info "Pulling image: $ghcr_image"
    if docker pull "$ghcr_image"; then
        print_success "Image pulled successfully"
        return 0
    else
        print_error "Failed to pull image: $ghcr_image"
        print_info "Check your GITHUB_PAT and network connection, or build/tag the image locally as: $ghcr_image"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Start Services
# -----------------------------------------------------------------------------
start_service() {
    local service_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local compose_file="$DEPLOY_ROOT/docker/docker-compose.report-generator-${service_name}.yml"

    if [[ ! -f "$compose_file" ]]; then
        print_error "Compose file not found: $compose_file"
        return 1
    fi

    print_info "Starting report-generator-${service_name}..."

    # Use -p to group with other portal containers
    local cmd="docker compose -p $project_name -f $compose_file --env-file $DEPLOY_ROOT/portal.env up -d"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        print_success "Report generator $service_name started"
        return 0
    else
        print_error "Failed to start report generator $service_name"
        return 1
    fi
}

wait_for_healthy() {
    local service_name="$1"
    local project_name="${PROJECT_NAME:-ezy-portal}"
    local container="${project_name}-report-generator-${service_name}"
    local timeout=120

    # Service container has no health check
    if [[ "$service_name" == "service" ]]; then
        print_info "Scheduler service started (no health check)"
        return 0
    fi

    print_info "Waiting for report-generator-${service_name} to be healthy..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")

        if [[ "$health" == "healthy" ]]; then
            print_success "Report generator $service_name is healthy"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    print_warning "Report generator $service_name did not become healthy within ${timeout}s"
    print_info "Check logs: docker logs $container"
    return 1
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    init_logging
    parse_arguments "$@"

    echo ""
    print_section "Adding Report Generator: $SERVICE_TYPE"

    # Load existing config
    if [[ -f "$DEPLOY_ROOT/portal.env" ]]; then
        load_config "$DEPLOY_ROOT/portal.env"
    else
        print_error "portal.env not found. Run ./install.sh first."
        exit 1
    fi

    # Pre-flight checks
    print_section "Step 1: Prerequisites"
    check_docker_installed || exit 1
    check_docker_running || exit 1
    check_portal_running || exit 1

    # GHCR login
    print_subsection "GitHub Container Registry"
    check_ghcr_login || exit 1

    # Ensure directory structure
    print_section "Step 2: Directory Structure"
    ensure_directory_structure

    # Determine which services to install
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

    # Check if services are already running
    for svc in "${services[@]}"; do
        check_service_not_running "$svc" || exit 0
    done

    # Pull images
    print_section "Step 3: Pull Images"
    for svc in "${services[@]}"; do
        if ! pull_image "$svc"; then
            exit 1
        fi
    done

    # Start services
    print_section "Step 4: Start Services"
    for svc in "${services[@]}"; do
        if ! start_service "$svc"; then
            exit 1
        fi
    done

    # Wait for healthy
    print_section "Step 5: Health Check"
    for svc in "${services[@]}"; do
        wait_for_healthy "$svc" || true
    done

    # Success output
    echo ""
    print_section "Installation Complete!"
    print_success "Report Generator ($SERVICE_TYPE) installed successfully!"
    echo ""

    local project_name="${PROJECT_NAME:-ezy-portal}"
    for svc in "${services[@]}"; do
        echo "  Container:  ${project_name}-report-generator-${svc}"
        echo "  Logs:       docker logs ${project_name}-report-generator-${svc}"
        if [[ "$svc" == "api" ]]; then
            echo "  API URL:    http://report-generator-api:5127/api/reports/"
            echo "  Health:     http://report-generator-api:5127/api/admin/health"
        fi
        echo ""
    done

    echo "Reports Directory: $DEPLOY_ROOT/report-generator/reports/"
    echo "Output Directory:  $DEPLOY_ROOT/report-generator/output/"
    echo ""

    log_info "Report Generator added: $SERVICE_TYPE (version: $REPORT_GENERATOR_VERSION)"
}

main "$@"
