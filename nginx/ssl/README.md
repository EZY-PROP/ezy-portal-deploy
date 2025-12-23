# SSL Certificates

This directory contains SSL certificates for the nginx reverse proxy.

## Required Files

- `server.crt` - SSL certificate
- `server.key` - Private key

## Generate Self-Signed Certificate

For development/testing, generate a self-signed certificate:

```bash
./generate-self-signed.sh localhost
```

Or manually:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout server.key \
  -out server.crt \
  -subj "/CN=localhost" \
  -addext "subjectAltName = DNS:localhost,IP:127.0.0.1"

chmod 600 server.key
chmod 644 server.crt
```

## Using Real Certificates

For production, use certificates from:

1. **Let's Encrypt** (free): https://letsencrypt.org/
2. **Commercial CA**: DigiCert, Sectigo, etc.

Copy your certificate files here:
- Copy your certificate to `server.crt`
- Copy your private key to `server.key`

## Certificate Chain

If you have a certificate chain (intermediate certificates), concatenate them:

```bash
cat your-certificate.crt intermediate.crt root.crt > server.crt
```

## Security Notes

- The `server.key` file should have permissions `600` (owner read/write only)
- Never commit real certificates to git
- The `.gitignore` excludes `*.crt`, `*.key`, and `*.pem` files
