# EZY Portal Deployment Package

Single-command deployment for EZY Portal. Clone this repository to your cloud server or customer environment and run `./install.sh`.

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/ezy-prop/portal-deploy.git
cd portal-deploy

# 2. Set your GitHub Personal Access Token
export GITHUB_PAT=ghp_your_token_here

# 3. Run the installer
./install.sh
```

## Prerequisites

- **Docker** with Docker Compose v2
- **GITHUB_PAT** environment variable (GitHub Personal Access Token with `read:packages` scope)
- **Ports 80 and 443** available (or configure custom ports)

### Getting a GitHub Personal Access Token

1. Go to https://github.com/settings/tokens
2. Generate new token (classic)
3. Select scope: `read:packages`
4. Copy the token and set it as an environment variable

## Installation Options

### Interactive Installation (Recommended)

```bash
export GITHUB_PAT=ghp_your_token
./install.sh
```

The wizard will guide you through:
- Infrastructure mode (full or external)
- Database configuration
- Redis and RabbitMQ setup
- Authentication (Azure AD / Google OAuth)
- SSL certificate setup
- Admin user configuration

### Non-Interactive Installation

```bash
# Install with full infrastructure (PostgreSQL, Redis, RabbitMQ as containers)
./install.sh --version 1.0.0 --full-infra --non-interactive

# Install with external infrastructure
./install.sh --version 1.0.0 --external-infra --non-interactive
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--version VERSION` | Install specific version (default: latest) |
| `--full-infra` | Deploy PostgreSQL, Redis, RabbitMQ as containers |
| `--external-infra` | Use existing external infrastructure |
| `--non-interactive` | Skip prompts, use defaults |
| `--skip-ssl` | Skip SSL certificate setup |
| `--help` | Show help message |

## Infrastructure Modes

### Full Infrastructure (`--full-infra`)

Deploys everything as Docker containers:
- PostgreSQL database
- Redis cache
- RabbitMQ message broker
- Nginx reverse proxy
- Portal application

Best for:
- New deployments
- Development/testing
- Self-contained installations

### External Infrastructure (`--external-infra`)

Connects to your existing services:
- Uses your PostgreSQL server
- Uses your Redis instance
- Uses your RabbitMQ (optional)
- Deploys Nginx and Portal only

Best for:
- Enterprise environments with existing databases
- Managed database services (RDS, Azure Database, etc.)
- Shared infrastructure

## Configuration

### Configuration Files

| File | Purpose |
|------|---------|
| `portal.env` | Main configuration (created during install) |
| `config/portal.env.template` | Complete configuration reference |
| `config/portal.env.full-infra` | Template for full infrastructure |
| `config/portal.env.external-infra` | Template for external infrastructure |

### Required Settings

At minimum, you must configure:

```env
# Admin user (auto-created on first startup)
ADMIN_EMAIL=admin@yourcompany.com

# Application URL (for OAuth redirects)
APPLICATION_URL=https://portal.yourcompany.com

# OAuth provider (at least one required)
AZURE_AD_TENANT_ID=your-tenant-id
AZURE_AD_CLIENT_ID=your-client-id
AZURE_AD_CLIENT_SECRET=your-secret
```

### SSL Certificates

Certificates are stored in `nginx/ssl/`:

```bash
# Generate self-signed certificate (development)
./nginx/ssl/generate-self-signed.sh localhost

# For production, copy your certificates:
cp your-certificate.crt nginx/ssl/server.crt
cp your-private-key.key nginx/ssl/server.key
```

## Upgrade

```bash
# Upgrade to latest version
./upgrade.sh

# Upgrade to specific version
./upgrade.sh --version 1.0.2

# Rollback to previous version
./upgrade.sh --rollback
```

### Upgrade Options

| Option | Description |
|--------|-------------|
| `--version VERSION` | Upgrade to specific version |
| `--skip-backup` | Skip backup before upgrade (not recommended) |
| `--rollback` | Rollback to previous version |
| `--force` | Force upgrade even if same version |

## Directory Structure

```
portal-deploy/
├── install.sh              # Main installation script
├── upgrade.sh              # Upgrade and rollback script
├── portal.env              # Your configuration (git-ignored)
├── .gitignore              # Ignores secrets and data
│
├── lib/                    # Shared bash libraries
│   ├── common.sh           # Utilities and output
│   ├── checks.sh           # Prerequisite validation
│   ├── config.sh           # Configuration management
│   ├── docker.sh           # Docker operations
│   ├── ssl.sh              # SSL certificate management
│   └── backup.sh           # Backup and restore
│
├── config/                 # Configuration templates
│   ├── portal.env.template
│   ├── portal.env.full-infra
│   └── portal.env.external-infra
│
├── docker/                 # Docker Compose files
│   ├── docker-compose.full.yml
│   └── docker-compose.portal-only.yml
│
├── nginx/                  # Nginx configuration
│   ├── nginx.conf
│   ├── conf.d/
│   ├── snippets/
│   └── ssl/
│
├── backups/                # Automatic backups (git-ignored)
├── logs/                   # Log files (git-ignored)
└── docs/                   # Additional documentation
```

## Common Operations

### View Logs

```bash
# Portal logs
docker logs ezy-portal

# All service logs
docker compose -f docker/docker-compose.full.yml logs

# Follow logs
docker logs -f ezy-portal
```

### Stop Services

```bash
# Full infrastructure
docker compose -f docker/docker-compose.full.yml --env-file portal.env down

# Portal only
docker compose -f docker/docker-compose.portal-only.yml --env-file portal.env down
```

### Restart Services

```bash
docker compose -f docker/docker-compose.full.yml --env-file portal.env restart
```

### Database Access

```bash
# Connect to PostgreSQL
docker exec -it ezy-portal-postgres psql -U postgres -d portal
```

### Create Backup

```bash
# The upgrade script creates automatic backups
# For manual backup:
source lib/backup.sh
create_full_backup "manual-backup"
```

## Troubleshooting

### Prerequisites Check Failed

```bash
# Check Docker
docker --version
docker compose version

# Check if Docker is running
sudo systemctl status docker

# Check GITHUB_PAT
echo $GITHUB_PAT
```

### Port Already in Use

```bash
# Check what's using ports 80/443
sudo ss -tuln | grep -E ':80|:443'

# Use custom ports in portal.env
HTTP_PORT=8080
HTTPS_PORT=8443
```

### Portal Not Healthy

```bash
# Check portal logs
docker logs ezy-portal

# Check container status
docker ps -a

# Check health endpoint
curl -k https://localhost/health
```

### Database Connection Issues

```bash
# Check PostgreSQL is running
docker ps | grep postgres

# Test connection
docker exec -it ezy-portal-postgres pg_isready -U postgres
```

### SSL Certificate Issues

```bash
# Regenerate self-signed certificate
./nginx/ssl/generate-self-signed.sh your-domain.com

# Check certificate validity
openssl x509 -in nginx/ssl/server.crt -text -noout
```

## Security Notes

- Never commit `portal.env` to git (contains secrets)
- SSL certificates are excluded from git
- Default passwords are auto-generated during installation
- Change default passwords for production
- Use proper SSL certificates for production (not self-signed)

## Support

- Issues: https://github.com/ezy-prop/portal-deploy/issues
- Documentation: https://docs.ezy-portal.com

## License

Proprietary - EZY Properties
