#!/bin/bash
# =============================================================================
# Generate Self-Signed SSL Certificate
# =============================================================================
# Usage: ./generate-self-signed.sh [domain] [days]
#
# Examples:
#   ./generate-self-signed.sh                    # localhost, 365 days
#   ./generate-self-signed.sh portal.company.com # custom domain
#   ./generate-self-signed.sh portal.company.com 730  # 2 years
# =============================================================================

set -e

DOMAIN="${1:-localhost}"
DAYS="${2:-365}"
SSL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Generating self-signed certificate..."
echo "  Domain: $DOMAIN"
echo "  Valid for: $DAYS days"
echo "  Output: $SSL_DIR/"

# Generate certificate with SAN support
openssl req -x509 -nodes -days "$DAYS" -newkey rsa:2048 \
    -keyout "$SSL_DIR/server.key" \
    -out "$SSL_DIR/server.crt" \
    -subj "/CN=$DOMAIN/O=EZY Portal/C=US" \
    -addext "subjectAltName = DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"

# Set proper permissions
chmod 600 "$SSL_DIR/server.key"
chmod 644 "$SSL_DIR/server.crt"

echo ""
echo "Certificate generated successfully!"
echo "  Certificate: $SSL_DIR/server.crt"
echo "  Private Key: $SSL_DIR/server.key"
echo ""
echo "Note: Self-signed certificates will show browser warnings."
echo "For production, use a certificate from a trusted CA."
