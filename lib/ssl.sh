#!/bin/bash
# =============================================================================
# EZY Portal - SSL Certificate Management
# =============================================================================
# SSL certificate generation, validation, and management
# =============================================================================

# Source common utilities if not already loaded
if [[ -z "${NC:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

SSL_DIR="${DEPLOY_ROOT}/nginx/ssl"

# -----------------------------------------------------------------------------
# Certificate Checks
# -----------------------------------------------------------------------------

check_ssl_certificates() {
    local ssl_dir="${1:-$SSL_DIR}"

    if [[ -f "$ssl_dir/server.crt" ]] && [[ -f "$ssl_dir/server.key" ]]; then
        return 0
    fi

    return 1
}

check_ssl_expiry() {
    local cert_file="${1:-$SSL_DIR/server.crt}"
    local warn_days="${2:-30}"

    if [[ ! -f "$cert_file" ]]; then
        return 1
    fi

    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)

    if [[ -z "$expiry_date" ]]; then
        print_error "Could not read certificate expiry"
        return 1
    fi

    local expiry_epoch
    local now_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null)
    now_epoch=$(date +%s)

    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_left -lt 0 ]]; then
        print_error "SSL certificate has EXPIRED"
        return 1
    elif [[ $days_left -lt $warn_days ]]; then
        print_warning "SSL certificate expires in $days_left days"
        return 0
    else
        print_success "SSL certificate valid for $days_left days"
        return 0
    fi
}

get_certificate_info() {
    local cert_file="${1:-$SSL_DIR/server.crt}"

    if [[ ! -f "$cert_file" ]]; then
        print_error "Certificate not found: $cert_file"
        return 1
    fi

    echo ""
    print_info "Certificate Information:"
    echo ""

    # Subject
    local subject
    subject=$(openssl x509 -subject -noout -in "$cert_file" 2>/dev/null | sed 's/subject=//')
    echo "  Subject: $subject"

    # Issuer
    local issuer
    issuer=$(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | sed 's/issuer=//')
    echo "  Issuer: $issuer"

    # Validity
    local start_date end_date
    start_date=$(openssl x509 -startdate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    end_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    echo "  Valid From: $start_date"
    echo "  Valid Until: $end_date"

    # SANs
    local sans
    sans=$(openssl x509 -text -noout -in "$cert_file" 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^\s*//')
    if [[ -n "$sans" ]]; then
        echo "  SANs: $sans"
    fi

    echo ""
}

validate_cert_key_pair() {
    local cert_file="${1:-$SSL_DIR/server.crt}"
    local key_file="${2:-$SSL_DIR/server.key}"

    if [[ ! -f "$cert_file" ]]; then
        print_error "Certificate not found: $cert_file"
        return 1
    fi

    if [[ ! -f "$key_file" ]]; then
        print_error "Private key not found: $key_file"
        return 1
    fi

    # Compare modulus of cert and key
    local cert_modulus key_modulus
    cert_modulus=$(openssl x509 -modulus -noout -in "$cert_file" 2>/dev/null | md5sum | awk '{print $1}')
    key_modulus=$(openssl rsa -modulus -noout -in "$key_file" 2>/dev/null | md5sum | awk '{print $1}')

    if [[ "$cert_modulus" == "$key_modulus" ]]; then
        print_success "Certificate and key match"
        return 0
    else
        print_error "Certificate and key do not match"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Certificate Generation
# -----------------------------------------------------------------------------

generate_self_signed_cert() {
    local domain="${1:-localhost}"
    local ssl_dir="${2:-$SSL_DIR}"
    local days="${3:-365}"

    print_info "Generating self-signed certificate for: $domain"

    mkdir -p "$ssl_dir"

    # Generate certificate with SAN support
    openssl req -x509 -nodes -days "$days" -newkey rsa:2048 \
        -keyout "$ssl_dir/server.key" \
        -out "$ssl_dir/server.crt" \
        -subj "/CN=$domain/O=EZY Portal/C=US" \
        -addext "subjectAltName = DNS:$domain,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    if [[ $? -eq 0 ]]; then
        # Set permissions
        chmod 600 "$ssl_dir/server.key"
        chmod 644 "$ssl_dir/server.crt"

        print_success "Self-signed certificate generated"
        print_info "Certificate location: $ssl_dir/server.crt"
        print_info "Private key location: $ssl_dir/server.key"
        print_warning "Self-signed certificates will show browser warnings"

        return 0
    else
        print_error "Failed to generate certificate"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Certificate Installation
# -----------------------------------------------------------------------------

install_certificates() {
    local cert_source="$1"
    local key_source="$2"
    local ssl_dir="${3:-$SSL_DIR}"

    if [[ ! -f "$cert_source" ]]; then
        print_error "Certificate file not found: $cert_source"
        return 1
    fi

    if [[ ! -f "$key_source" ]]; then
        print_error "Key file not found: $key_source"
        return 1
    fi

    # Validate the pair before copying
    if ! validate_cert_key_pair "$cert_source" "$key_source"; then
        return 1
    fi

    mkdir -p "$ssl_dir"

    cp "$cert_source" "$ssl_dir/server.crt"
    cp "$key_source" "$ssl_dir/server.key"

    chmod 600 "$ssl_dir/server.key"
    chmod 644 "$ssl_dir/server.crt"

    print_success "Certificates installed to: $ssl_dir"

    return 0
}

# -----------------------------------------------------------------------------
# SSL Setup Wizard
# -----------------------------------------------------------------------------

setup_ssl_interactive() {
    local ssl_dir="${1:-$SSL_DIR}"
    local domain="${2:-localhost}"

    print_subsection "SSL Certificate Setup"

    # Check for existing certificates
    if check_ssl_certificates "$ssl_dir"; then
        print_info "Existing certificates found"
        get_certificate_info "$ssl_dir/server.crt"

        if check_ssl_expiry "$ssl_dir/server.crt"; then
            if ! confirm "Replace existing certificates?" "n"; then
                print_info "Keeping existing certificates"
                return 0
            fi
        fi
    fi

    echo ""
    print_info "SSL Certificate Options:"
    echo ""
    echo "  1. Generate self-signed certificate (quick, for testing)"
    echo "  2. Provide your own certificate files"
    echo "  3. Skip SSL setup (not recommended)"
    echo ""

    while true; do
        read -r -p "Enter choice [1-3]: " choice
        case $choice in
            1)
                prompt_input "Domain name for certificate" "$domain" domain
                generate_self_signed_cert "$domain" "$ssl_dir"
                return $?
                ;;
            2)
                local cert_path key_path

                prompt_input "Path to certificate file (.crt/.pem)" "" cert_path
                prompt_input "Path to private key file (.key)" "" key_path

                install_certificates "$cert_path" "$key_path" "$ssl_dir"
                return $?
                ;;
            3)
                print_warning "Skipping SSL setup"
                print_warning "Portal will NOT be accessible via HTTPS"
                return 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Let's Encrypt (Future Enhancement)
# -----------------------------------------------------------------------------

setup_letsencrypt() {
    local domain="$1"
    local email="$2"

    print_error "Let's Encrypt integration is not yet implemented"
    print_info "For production, we recommend using Let's Encrypt with certbot"
    print_info "See: https://certbot.eff.org/"

    return 1
}

# -----------------------------------------------------------------------------
# Trust Certificate (Development)
# -----------------------------------------------------------------------------

trust_self_signed_cert() {
    local ssl_dir="${1:-$SSL_DIR}"
    local cert_file="$ssl_dir/server.crt"

    if [[ ! -f "$cert_file" ]]; then
        print_error "Certificate not found: $cert_file"
        return 1
    fi

    print_info "To trust this certificate on your system:"
    echo ""

    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        echo "  macOS:"
        echo "    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $cert_file"
    elif [[ -f /etc/debian_version ]]; then
        # Debian/Ubuntu
        echo "  Debian/Ubuntu:"
        echo "    sudo cp $cert_file /usr/local/share/ca-certificates/"
        echo "    sudo update-ca-certificates"
    elif [[ -f /etc/redhat-release ]]; then
        # RHEL/CentOS/Fedora
        echo "  RHEL/CentOS/Fedora:"
        echo "    sudo cp $cert_file /etc/pki/ca-trust/source/anchors/"
        echo "    sudo update-ca-trust"
    else
        echo "  Please consult your OS documentation for adding trusted certificates"
    fi

    echo ""
    print_info "For browsers, you may need to manually accept the certificate on first visit"
}
