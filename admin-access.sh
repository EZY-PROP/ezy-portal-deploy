#!/bin/bash
# =============================================================================
# EZY Portal - Admin Access Toggle
# =============================================================================
# Enable or disable localhost port bindings for maintenance access.
#
# Usage:
#   ./admin-access.sh enable    # Expose ports on 127.0.0.1
#   ./admin-access.sh disable   # Remove port bindings
#   ./admin-access.sh status    # Check current status
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"

ADMIN_COMPOSE="$SCRIPT_DIR/docker/docker-compose.admin.yml"
ADMIN_ENABLED_FLAG="$SCRIPT_DIR/.admin-access-enabled"

show_help() {
    echo "EZY Portal - Admin Access Toggle"
    echo ""
    echo "Usage: ./admin-access.sh <command>"
    echo ""
    echo "Commands:"
    echo "  enable     Expose service ports on localhost (127.0.0.1)"
    echo "  disable    Remove localhost port bindings"
    echo "  status     Check if admin access is enabled"
    echo ""
    echo "Exposed Ports (when enabled):"
    echo "  PostgreSQL:      127.0.0.1:5432"
    echo "  Redis:           127.0.0.1:6379"
    echo "  RabbitMQ AMQP:   127.0.0.1:5672"
    echo "  RabbitMQ UI:     127.0.0.1:15672"
    echo "  Report API:      127.0.0.1:5127"
    echo "  Portal API:      127.0.0.1:8080"
    echo ""
    echo "SSH Tunnel Example:"
    echo "  ssh -L 5432:127.0.0.1:5432 -L 15672:127.0.0.1:15672 user@server"
    echo ""
    echo "SECURITY: Only enable when needed, disable when done."
}

get_compose_args() {
    # Load config
    if [[ -f "$SCRIPT_DIR/portal.env" ]]; then
        load_config "$SCRIPT_DIR/portal.env"
    fi

    local infra_mode="${INFRASTRUCTURE_MODE:-full}"
    local project_name="${PROJECT_NAME:-ezy-portal}"

    # Get base compose file
    local base_compose
    case "$infra_mode" in
        full)
            base_compose="$SCRIPT_DIR/docker/docker-compose.full.yml"
            ;;
        external)
            base_compose="$SCRIPT_DIR/docker/docker-compose.external.yml"
            ;;
        *)
            base_compose="$SCRIPT_DIR/docker/docker-compose.full.yml"
            ;;
    esac

    local args="-p $project_name -f $base_compose"

    # Add module compose files for running modules
    local modules=("items" "bp" "prospects")
    for m in "${modules[@]}"; do
        local m_compose="$SCRIPT_DIR/docker/docker-compose.module-${m}.yml"
        local container="${project_name}-${m}"
        if [[ -f "$m_compose" ]] && docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            args="$args -f $m_compose"
        fi
    done

    # Add customer module compose files
    for f in "$SCRIPT_DIR/docker/docker-compose.module-customer-"*.yml; do
        if [[ -f "$f" ]]; then
            local module_name=$(basename "$f" | sed 's/docker-compose.module-customer-//' | sed 's/.yml//')
            if docker ps --format '{{.Names}}' | grep -q "^${module_name}$"; then
                args="$args -f $f"
            fi
        fi
    done

    # Add report generator if running
    if docker ps --format '{{.Names}}' | grep -q "^ezy-report-generator-api$"; then
        local rg_compose="$SCRIPT_DIR/docker/docker-compose.report-generator-api.yml"
        if [[ -f "$rg_compose" ]]; then
            args="$args -f $rg_compose"
        fi
    fi

    echo "$args"
}

enable_admin() {
    print_section "Enabling Admin Access"

    if [[ ! -f "$ADMIN_COMPOSE" ]]; then
        print_error "Admin compose file not found: $ADMIN_COMPOSE"
        exit 1
    fi

    # Load config to get PROJECT_NAME
    if [[ -f "$SCRIPT_DIR/portal.env" ]]; then
        source "$SCRIPT_DIR/lib/config.sh"
        load_config "$SCRIPT_DIR/portal.env"
    fi

    local compose_args
    compose_args=$(get_compose_args)

    print_info "Adding localhost port bindings..."

    local cmd="docker compose $compose_args -f $ADMIN_COMPOSE --env-file $SCRIPT_DIR/portal.env up -d"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        touch "$ADMIN_ENABLED_FLAG"

        # Reload nginx to refresh DNS after container IPs changed
        local project_name="${PROJECT_NAME:-ezy-portal}"
        local nginx_container="${project_name}-nginx"
        if docker ps --format '{{.Names}}' | grep -q "^${nginx_container}$"; then
            print_info "Reloading nginx to refresh DNS..."
            docker exec "$nginx_container" nginx -s reload 2>/dev/null || true
        fi

        echo ""
        print_success "Admin access enabled!"
        echo ""
        echo "Available ports (localhost only):"
        echo "  PostgreSQL:    127.0.0.1:5432"
        echo "  Redis:         127.0.0.1:6379"
        echo "  RabbitMQ AMQP: 127.0.0.1:5672"
        echo "  RabbitMQ UI:   http://127.0.0.1:15672"
        echo "  Report API:    http://127.0.0.1:5127/swagger"
        echo "  Portal API:    http://127.0.0.1:8080/swagger"
        echo ""
        echo "Quick commands:"
        echo "  psql -h 127.0.0.1 -U postgres -d portal"
        echo "  redis-cli -h 127.0.0.1"
        echo "  curl http://127.0.0.1:5127/api/admin/health"
        echo ""
        print_warning "Remember to disable when done: ./admin-access.sh disable"
    else
        print_error "Failed to enable admin access"
        exit 1
    fi
}

disable_admin() {
    print_section "Disabling Admin Access"

    # Load config to get PROJECT_NAME
    if [[ -f "$SCRIPT_DIR/portal.env" ]]; then
        source "$SCRIPT_DIR/lib/config.sh"
        load_config "$SCRIPT_DIR/portal.env"
    fi

    local compose_args
    compose_args=$(get_compose_args)

    print_info "Removing localhost port bindings..."

    # Recreate without admin overlay to remove port bindings
    local cmd="docker compose $compose_args --env-file $SCRIPT_DIR/portal.env up -d"
    log_info "Running: $cmd"

    if eval "$cmd"; then
        rm -f "$ADMIN_ENABLED_FLAG"

        # Reload nginx to refresh DNS after container IPs changed
        local project_name="${PROJECT_NAME:-ezy-portal}"
        local nginx_container="${project_name}-nginx"
        if docker ps --format '{{.Names}}' | grep -q "^${nginx_container}$"; then
            print_info "Reloading nginx to refresh DNS..."
            docker exec "$nginx_container" nginx -s reload 2>/dev/null || true
        fi

        print_success "Admin access disabled - ports no longer exposed"
    else
        print_error "Failed to disable admin access"
        exit 1
    fi
}

show_status() {
    echo ""
    if [[ -f "$ADMIN_ENABLED_FLAG" ]]; then
        print_success "Admin access is ENABLED"
        echo ""
        echo "Checking port bindings..."
        echo ""

        # Check which ports are actually listening
        local ports=("5432:PostgreSQL" "6379:Redis" "5672:RabbitMQ" "15672:RabbitMQ UI" "5127:Report API" "8080:Portal API")
        for port_info in "${ports[@]}"; do
            local port="${port_info%%:*}"
            local name="${port_info#*:}"
            if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
                echo "  [OPEN] 127.0.0.1:$port - $name"
            else
                echo "  [----] 127.0.0.1:$port - $name (not running)"
            fi
        done
    else
        print_info "Admin access is DISABLED"
        echo "Run './admin-access.sh enable' to expose ports"
    fi
    echo ""
}

# Main
init_logging

case "${1:-}" in
    enable)
        enable_admin
        ;;
    disable)
        disable_admin
        ;;
    status)
        show_status
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
