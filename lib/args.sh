#!/bin/bash
# =============================================================================
# EZY Portal - Argument Parsing Helpers
# =============================================================================
# Reusable argument parsing utilities for deployment scripts
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# -----------------------------------------------------------------------------
# Standard Option Handlers
# -----------------------------------------------------------------------------

# Parse common options that most scripts share
# Usage: parse_common_options "$@"
# Sets: DEBUG, VERBOSE, and returns remaining args via REMAINING_ARGS array
# Returns: 0 if help requested (caller should exit), 1 otherwise
parse_common_options() {
    REMAINING_ARGS=()
    DEBUG="${DEBUG:-false}"
    VERBOSE="${VERBOSE:-false}"

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --debug)
                DEBUG=true
                export DEBUG
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                export VERBOSE
                shift
                ;;
            --help|-h)
                return 0
                ;;
            *)
                REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done

    return 1
}

# -----------------------------------------------------------------------------
# Option Value Helpers
# -----------------------------------------------------------------------------

# Get option value from args array
# Usage: get_option_value "--option" "$@"
# Returns: value if found, empty otherwise
get_option_value() {
    local option="$1"
    shift

    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" == "$option" && -n "$2" && "$2" != "--"* ]]; then
            echo "$2"
            return 0
        fi
        shift
    done

    return 1
}

# Check if flag is present
# Usage: has_flag "--flag" "$@"
# Returns: 0 if present, 1 otherwise
has_flag() {
    local flag="$1"
    shift

    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" == "$flag" ]]; then
            return 0
        fi
        shift
    done

    return 1
}

# Get positional argument (non-option arg)
# Usage: get_positional_arg <index> "$@"
# Returns: argument value or empty
get_positional_arg() {
    local index="$1"
    shift
    local count=0

    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" != "--"* && "$1" != "-"* ]]; then
            if [[ $count -eq $index ]]; then
                echo "$1"
                return 0
            fi
            ((count++))
        elif [[ "$1" == "--"* && -n "$2" && "$2" != "--"* ]]; then
            # Skip option with value
            shift
        fi
        shift
    done

    return 1
}

# -----------------------------------------------------------------------------
# Validation Helpers
# -----------------------------------------------------------------------------

# Require at least N arguments
# Usage: require_args <count> <script_name> "$@"
require_args() {
    local count="$1"
    local script="$2"
    shift 2

    if [[ $# -lt $count ]]; then
        print_error "Not enough arguments"
        print_info "Run '$script --help' for usage"
        return 1
    fi
    return 0
}

# Validate argument is one of allowed values
# Usage: validate_arg <value> <allowed1> <allowed2> ...
validate_arg() {
    local value="$1"
    shift

    for allowed in "$@"; do
        if [[ "$value" == "$allowed" ]]; then
            return 0
        fi
    done

    return 1
}

# -----------------------------------------------------------------------------
# Help Text Formatting
# -----------------------------------------------------------------------------

# Print formatted help header
# Usage: print_help_header "Script Name" "Brief description"
print_help_header() {
    local name="$1"
    local desc="$2"
    echo "$name"
    echo ""
    echo "$desc"
    echo ""
}

# Print usage line
# Usage: print_help_usage "./script.sh <arg> [OPTIONS]"
print_help_usage() {
    echo "Usage: $1"
    echo ""
}

# Print section header for help
# Usage: print_help_section "Options"
print_help_section() {
    echo "$1:"
}

# Print option line
# Usage: print_help_option "-h, --help" "Show this help message"
print_help_option() {
    printf "  %-20s %s\n" "$1" "$2"
}

# Print example line
# Usage: print_help_example "./script.sh foo" "Run with foo"
print_help_example() {
    echo "  $1"
    if [[ -n "${2:-}" ]]; then
        echo "    $2"
    fi
}
