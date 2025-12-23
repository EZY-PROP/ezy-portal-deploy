# API Key Auto-Provisioning

This document explains how DevOps scripts can automatically provision API keys for micro-services without manual admin intervention.

## Overview

When adding micro-frontend modules to a portal installation, each module requires an API key to authenticate with the portal backend. Previously, this required:

1. Logging into Portal Admin UI
2. Generating an API key manually
3. Copying the key to `portal.env`
4. Running `add-module.sh` with `--api-key`

With **deployment secret authentication**, this process is now automated.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│  install.sh                                                  │
│     └─→ Auto-generates DEPLOYMENT_SECRET (64 chars)         │
│     └─→ Saved to portal.env                                 │
│                                                              │
│  add-module.sh items                                         │
│     └─→ POST /api/service-api-keys/provision                │
│           Header: X-Deployment-Secret: ${DEPLOYMENT_SECRET} │
│           Body: { "serviceName": "items" }                  │
│     └─→ Saves returned API key to portal.env                │
└─────────────────────────────────────────────────────────────┘
```

## Usage

### Adding a Module (Automatic)

```bash
# API key is auto-provisioned using DEPLOYMENT_SECRET
./add-module.sh items
./add-module.sh bp
./add-module.sh prospects
```

### Adding a Module (Manual Key)

```bash
# Use explicit API key (backward compatible)
./add-module.sh items --api-key abc123def456
```

### Priority Order

When `add-module.sh` runs, it determines the API key using this priority:

1. **Explicit `--api-key`** - If provided on command line
2. **Existing key in `portal.env`** - If already configured
3. **Auto-provision** - Via `DEPLOYMENT_SECRET` and backend API
4. **Manual instructions** - Fallback if all else fails

## Configuration

### DEPLOYMENT_SECRET

The deployment secret is automatically generated during `install.sh` and stored in `portal.env`:

```bash
# portal.env
DEPLOYMENT_SECRET=<64-character-alphanumeric-string>
```

**Security notes:**
- Generated using cryptographically secure random bytes
- Never transmitted externally (stays on server)
- Only processes with access to `portal.env` can provision keys

### Regenerating the Secret

If you need to regenerate the deployment secret:

```bash
# Remove existing secret
sed -i '/^DEPLOYMENT_SECRET=/d' portal.env

# Restart portal to pick up the change
docker compose restart portal

# Next add-module.sh will fail until install.sh regenerates it
# Or manually generate:
echo "DEPLOYMENT_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64)" >> portal.env
```

## API Endpoint

### POST /api/service-api-keys/provision

Provisions an API key for a micro-service.

**Authentication:** `X-Deployment-Secret` header (not user authentication)

**Request:**
```json
{
  "serviceName": "items",
  "description": "Optional description"
}
```

**Response (new key):**
```json
{
  "serviceName": "items",
  "keyId": "550e8400-e29b-41d4-a716-446655440000",
  "isNewKey": true,
  "apiKey": "abc123...",
  "message": "API key generated successfully. Save this key securely - it will not be shown again.",
  "expiresAt": null
}
```

**Response (existing key):**
```json
{
  "serviceName": "items",
  "keyId": "550e8400-e29b-41d4-a716-446655440000",
  "isNewKey": false,
  "apiKey": null,
  "message": "API key already exists for this service. Use the existing key.",
  "expiresAt": null
}
```

**Error responses:**
- `401 Unauthorized` - Invalid or missing deployment secret
- `503 Service Unavailable` - `DEPLOYMENT_SECRET` not configured on server
- `400 Bad Request` - Missing service name

## Idempotent Behavior

The provision endpoint is **idempotent**:

- First call for a service → generates new key, returns it
- Subsequent calls → returns confirmation without generating new key
- Safe to call multiple times without side effects

This means:
- Running `add-module.sh items` twice won't create duplicate keys
- If a key already exists, the script uses the existing one from `portal.env`

## Troubleshooting

### "DEPLOYMENT_SECRET not set"

The deployment secret wasn't generated during installation.

**Solution:**
```bash
# Generate manually
echo "DEPLOYMENT_SECRET=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64)" >> portal.env

# Or re-run install
./install.sh
```

### "Invalid deployment secret"

The secret in `portal.env` doesn't match what the portal has.

**Solution:**
```bash
# Restart portal to reload environment
docker compose restart portal
```

### "Failed to connect to portal API"

The portal isn't running or isn't accessible.

**Solution:**
```bash
# Check portal status
docker ps | grep portal

# Check portal health
curl -k https://localhost/health

# View portal logs
docker logs ezy-portal
```

### "API key exists on server but not in portal.env"

A key was provisioned previously but `portal.env` was reset.

**Solution:**
1. Go to Portal Admin → API Keys
2. Find the key for the module
3. Either revoke it (to allow re-provisioning) or copy it manually

## Security Considerations

1. **Secret stays on server** - `DEPLOYMENT_SECRET` is only in `portal.env`
2. **No admin bypass** - Provision endpoint doesn't bypass normal admin auth for other operations
3. **Audit logging** - All provisioning requests are logged with service name and IP
4. **Constant-time comparison** - Secret validation uses timing-safe comparison
5. **HTTPS recommended** - In production, always use HTTPS for the provision endpoint
