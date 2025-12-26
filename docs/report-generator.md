# Report Generator

Optional PDF report generation service for EZY Portal.

## Overview

The Report Generator provides two optional services:

| Service | Description |
|---------|-------------|
| **API** | REST API for on-demand report generation |
| **Service** | Background scheduler for scheduled/automated reports |

Both services connect to external customer databases (not the portal database).

## Prerequisites

- Portal must be running and healthy
- Docker and Docker Compose installed
- Access to GHCR (or local images with `--local` flag)

## Installation

### Install API Only

```bash
./add-report-generator.sh api
```

### Install Scheduler Service Only

```bash
./add-report-generator.sh service
```

### Install Both

```bash
./add-report-generator.sh all
```

### Options

| Option | Description |
|--------|-------------|
| `--version VER` | Specific image version (default: latest) |
| `--local` | Use local Docker image instead of GHCR |

### Examples

```bash
# Install API with specific version
./add-report-generator.sh api --version 1.0.0

# Install both using local images
./add-report-generator.sh all --local
```

---

## Removal

### Remove API Only

```bash
./remove-report-generator.sh api
```

### Remove Scheduler Service Only

```bash
./remove-report-generator.sh service
```

### Remove Both

```bash
./remove-report-generator.sh all
```

### Options

| Option | Description |
|--------|-------------|
| `--force, -f` | Remove without confirmation |
| `--purge` | Also remove output and logs directories |

### Examples

```bash
# Remove without confirmation
./remove-report-generator.sh all --force

# Remove and clean up data
./remove-report-generator.sh all --purge
```

---

## Directory Structure

```
report-generator/
├── reports/           # Customer-provided report definitions
│   └── {report-name}/
│       ├── report.json      # Report configuration with inline datasource
│       ├── *.sql            # SQL query files
│       └── plugin.dll       # Compiled report design
├── output/            # Generated PDF files
└── logs/              # Application logs
    ├── api/
    └── service/
```

---

## Adding Reports

Reports are self-contained folders in `report-generator/reports/`. Each report folder contains:

### report.json

```json
{
  "id": "customer-invoice",
  "name": "Customer Invoice",
  "description": "Generate customer invoices",
  "designId": "CustomerInvoiceDesign",
  "enabled": true,
  "datasource": {
    "providerType": "postgresql",
    "connectionString": "Server=${CUSTOMER_DB_HOST};Port=5432;Database=${CUSTOMER_DB_NAME};Username=${CUSTOMER_DB_USER};Password=${CUSTOMER_DB_PASSWORD};",
    "commandTimeout": 30
  },
  "parameters": [
    {
      "name": "customerId",
      "type": "string",
      "required": true
    }
  ],
  "queryFile": "query.sql"
}
```

### Database Connection

Connection strings support environment variable substitution using `${VAR_NAME}` syntax. Add customer-specific database credentials to `portal.env`:

```bash
# Customer database credentials
CUSTOMER_DB_HOST=db.customer.com
CUSTOMER_DB_NAME=customer_db
CUSTOMER_DB_USER=report_user
CUSTOMER_DB_PASSWORD=secret
```

Supported database providers:
- `postgresql` - PostgreSQL
- `mssql` - SQL Server
- `hana` - SAP HANA

---

## Configuration

Email settings are automatically mapped from `portal.env`:

| Portal Variable | Report Generator |
|-----------------|------------------|
| `Email__SmtpHost` | SMTP server |
| `Email__SmtpPort` | SMTP port |
| `Email__Username` | SMTP username |
| `Email__Password` | SMTP password |
| `Email__UseSsl` | Use TLS |
| `Email__FromAddress` | Sender email |
| `Email__FromName` | Sender name |

No additional configuration is needed if email is already configured for the portal.

---

## Accessing the Services

Services are accessible via the Docker network only (no external proxy):

### API Endpoints

From other portal services:

```
http://report-generator-api:5127/api/reports/generate
http://report-generator-api:5127/api/admin/health
http://report-generator-api:5127/api/admin/reports
http://report-generator-api:5127/api/admin/designs
```

### Container Names

```
${PROJECT_NAME}-report-generator-api
${PROJECT_NAME}-report-generator-service
```

---

## Managing Services

### View Logs

```bash
# API logs
docker logs ezy-portal-report-generator-api

# Service logs
docker logs ezy-portal-report-generator-service

# Follow logs
docker logs -f ezy-portal-report-generator-api
```

### Check Health

```bash
# Container health status
docker inspect --format='{{.State.Health.Status}}' ezy-portal-report-generator-api

# HTTP health check (from within the network)
docker exec ezy-portal curl -s http://report-generator-api:5127/api/admin/health
```

### Restart Services

```bash
docker restart ezy-portal-report-generator-api
docker restart ezy-portal-report-generator-service
```

---

## Troubleshooting

### Service not starting

```bash
# Check container logs
docker logs ezy-portal-report-generator-api

# Check if image exists
docker images | grep ezy-report-generator
```

### Email not working

Verify email settings in `portal.env`:

```bash
grep "Email__" portal.env
```

### Database connection issues

1. Check environment variables are set in `portal.env`
2. Verify the database is accessible from the Docker network
3. Check connection string in `report.json`

### Reports not found

1. Verify report folder exists in `report-generator/reports/`
2. Check that `report.json` is valid JSON
3. Ensure `plugin.dll` is present if using custom designs

---

## Updating

To update to a new version:

```bash
# Remove existing
./remove-report-generator.sh all --force

# Install new version
./add-report-generator.sh all --version 1.1.0
```

Or with local images:

```bash
# Pull new images
docker pull ghcr.io/ezy-ts/ezy-report-generator-api:1.1.0
docker pull ghcr.io/ezy-ts/ezy-report-generator-service:1.1.0

# Recreate containers
./remove-report-generator.sh all --force
./add-report-generator.sh all --local
```
