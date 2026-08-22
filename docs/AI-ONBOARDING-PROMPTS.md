<!--
──────────────────────────────────────────────────────────────────
🏢 Company Name: Bonifade Technologies
👨‍💻 Developer: Bowofade Oyerinde
🐙 GitHub: oyenet1
📅 Created Date: 2026-08-22
🔄 Updated Date: 2026-08-22
──────────────────────────────────────────────────────────────────
-->

# 🤖 AI Prompts for Service Onboarding & Zero-Touch Monitoring

Use these copy-pasteable prompts when asking any AI coding assistant to build, instrument, or deploy a new service that connects to the shared **`infra`** VPS stack.

---

## 📑 Table of Contents

1. [🌟 Master Prompt (Complete App Setup)](#1--master-prompt-complete-app-setup)
2. [⚡ Framework-Specific Prompts](#2--framework-specific-prompts)
   - [TypeScript / Node.js (Hono / Bun / Express)](#option-a-typescript--nodejs-hono--bun--express)
   - [Python (FastAPI / Starlette)](#option-b-python-fastapi--starlette)
   - [Go (Chi / Gin / Echo / Standard Library)](#option-c-go-chi--gin--echo)
3. [🚢 Docker Swarm & Target Registration Prompt](#3--docker-swarm--target-registration-prompt)
4. [🔍 Quick Reference Table for Prompts](#4--quick-reference-table-for-prompts)

---

## 1. 🌟 Master Prompt (Complete App Setup)

> **When to use:** Give this prompt to an AI when starting a new service from scratch or refactoring an existing project to integrate with your VPS infrastructure and monitoring.

```markdown
Please instrument this application and configure its deployment to connect with our shared VPS infrastructure and monitoring stack (`infra`). Follow these exact requirements:

1. METRICS INSTRUMENTATION:
   - Expose Prometheus text-format metrics on `GET /v1/metrics` (with an alias on `GET /metrics`).
   - Do NOT require any authentication token on `/metrics` or `/v1/metrics`.
   - Collect runtime and process metrics.
   - Collect HTTP request metrics with normalized route paths (collapse IDs, UUIDs, and numeric tokens to `:id` to prevent high cardinality):
     * `http_requests_total{method, path, status}` (Counter)
     * `http_request_duration_seconds{method, path, status}` (Histogram with buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])

2. DOCKER SWARM DEPLOYMENT:
   - In `docker-swarm.yml`, attach the service to the external `infra` overlay network:
     ```yaml
     services:
       app:
         networks:
           - infra
     networks:
       infra:
         external: true
     ```

3. DATABASE & REDIS CONNECTIONS:
   - PostgreSQL (PgBouncer): `postgres://<user>:<password>@pgbouncer:6432/<dbname>`
   - PostgreSQL Direct (Admin/Migrations): `postgres://<user>:<password>@postgres:5432/<dbname>`
   - Redis (HAProxy): `redis://:<password>@redis-proxy:6379/<db_index>`

4. PROMETHEUS TARGET REGISTRATION:
   - Create a target JSON file in the infra repository under `monitoring/targets/<app-name>.json`:
     ```json
     [
       {
         "targets": ["<stack-name>_<service-name>:<port>"],
         "labels": {
           "job": "apps",
           "service": "<app-name>",
           "env": "production",
           "metrics_path": "/v1/metrics",
           "scheme": "http"
         }
       }
     ]
     ```
   - For staging environments, use `"env": "staging"` and filename `<app-name>-staging.json`.
```

---

## 2. ⚡ Framework-Specific Prompts

### Option A: TypeScript / Node.js (Hono / Bun / Express)

> **When to use:** Adding Prometheus metrics to a Node.js, Bun, or Hono/Express API.

```markdown
Add Prometheus metrics to this TypeScript/Node.js application using `prom-client`:

1. Initialize a `Registry` and collect default process metrics (`collectDefaultMetrics`).
2. Create and export the following metrics:
   - `http_requests_total` (Counter with labels: `method`, `path`, `status`)
   - `http_request_duration_seconds` (Histogram with labels: `method`, `path`, `status` and buckets: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]`)
   - `http_requests_in_flight` (Gauge with labels: `method`, `path`)
3. Implement an HTTP middleware that:
   - Normalizes path segments (replaces UUIDs, integer IDs, and 20+ char alphanumeric tokens with `:id`).
   - Measures request duration and increments total count with the final HTTP status code.
4. Expose the metrics endpoint at `GET /v1/metrics` and `GET /metrics`:
   - Serve `registry.metrics()` with content-type `registry.contentType`.
   - Ensure the endpoint is open (NO authentication token required).
```

---

### Option B: Python (FastAPI / Starlette)

> **When to use:** Adding Prometheus metrics to a Python FastAPI backend.

```markdown
Add Prometheus metrics to this FastAPI application using `prometheus-client` or `prometheus-fastapi-instrumentator`:

1. Instrument all HTTP routes to record:
   - Request counts by `method`, `path`, and `status`.
   - Request latency histograms with standard buckets.
2. Ensure templated route paths (e.g. `/users/{user_id}`) are used as the `path` label instead of expanded IDs.
3. Expose the metrics endpoint on both `GET /v1/metrics` and `GET /metrics`.
4. Ensure the metrics endpoints are publicly accessible without authentication dependencies.
```

---

### Option C: Go (Chi / Gin / Echo)

> **When to use:** Adding Prometheus metrics to a Go backend service.

```markdown
Add Prometheus metrics to this Go HTTP service using `github.com/prometheus/client_golang/prometheus`:

1. Register `http_requests_total` (CounterVec) and `http_request_duration_seconds` (HistogramVec) with labels `method`, `path`, `status`.
2. Add an HTTP middleware that measures execution latency and records response status code with normalized paths.
3. Mount `promhttp.Handler()` at `/v1/metrics` and `/metrics` without authentication.
```

---

## 3. 🚢 Docker Swarm & Target Registration Prompt

> **When to use:** When deploying the application to the VPS and registering it with Prometheus and Grafana.

```markdown
We are deploying `<app-name>` on our VPS Docker Swarm attached to the shared `infra` stack. Please configure the deployment:

1. Update `docker-swarm.yml` so the service connects to the external `infra` network:
   ```yaml
   services:
     app:
       networks:
         - infra
   networks:
     infra:
       external: true
   ```
2. Create the target file in the infra stack: `monitoring/targets/<app-name>.json`:
   ```json
   [
     {
       "targets": ["<stack-name>_<service-name>:<port>"],
       "labels": {
         "job": "apps",
         "service": "<app-name>",
         "env": "<production|staging>",
         "metrics_path": "/v1/metrics",
         "scheme": "http"
       }
     }
   ]
   ```
3. Confirm that Prometheus automatically discovers the target within 30 seconds and that the app is visible in the Grafana "App Performance & Errors" dashboard dropdown.
```

---

## 4. 🔍 Quick Reference Table for Prompts

| Resource | Value | Note |
|---|---|---|
| **Docker Overlay Network** | `infra` | Must specify `external: true` |
| **PgBouncer (Postgres)** | `pgbouncer:6432` | Standard pooled DB access |
| **Direct Postgres** | `postgres:5432` | Migrations / admin scripts |
| **Redis Proxy** | `redis-proxy:6379` | HAProxy to Redis Master |
| **Metrics Endpoints** | `/v1/metrics`, `/metrics` | Public text/plain (no token) |
| **Target Directory** | `monitoring/targets/*.json` | Auto-scanned every 30 seconds |
| **Grafana Dashboards** | Auto-filtered by `$env` and `$service` | Dropdowns update automatically |
| **Loki Log Aggregation** | Automatic via Alloy | Derived from Docker container logs |
