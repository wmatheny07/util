# /opt/util — Peak Precision Data Utilities

Helper scripts for managing the PPD stack, environment configuration, dbt workflows, and infrastructure setup.

---

## Stack Management

### `stack.sh`
Primary wrapper around `docker-compose` for managing named stacks with injected runtime environments.

```bash
stack.sh -f <compose.yml> [-f <override.yml>] -e <runtime.env> [-p <project>] <cmd> [services...]
```

**Commands:** `up`, `down`, `stop`, `restart`, `logs`, `ps`

**Flags:**
- `-f` — compose file(s) (repeatable)
- `-e` — runtime env file (post `op inject`, e.g. `/opt/config/runtime/.env.all`)
- `-p` — docker-compose project name
- `-k / --keep-env` — do not delete the injected env file after the run

**Examples:**
```bash
# Bring up the full core stack
stack.sh -f /opt/ppd/stacks/core/docker-compose.core.yml -e /opt/config/runtime/.env.all -p core up

# Restart a single service
stack.sh -f /opt/ppd/stacks/core/docker-compose.core.yml -e /opt/config/runtime/.env.all -p core restart nginx

# Tail logs for mlflow
stack.sh -f /opt/ppd/stacks/core/docker-compose.core.yml -e /opt/config/runtime/.env.all -p core logs mlflow
```

### `docker-up-nginx.sh`
Brings up the nginx reverse proxy service using the production env file.

---

## dbt Utilities

### `dbt-run.sh`
Run ad-hoc dbt commands (build, test, run, compile, ls) against the project using the correct Docker container and `prod` target. Automatically regenerates dbt docs when `--full-refresh` is used; pass `--docs` to trigger doc generation on any command.

```bash
dbt-run.sh [--docs] <dbt-command> [dbt-args...]
```

**Examples:**
```bash
# Full refresh a single model (docs auto-regenerated)
dbt-run.sh build --select fct_workout_summary --full-refresh

# Build with explicit doc regeneration
dbt-run.sh build --select +fct_resting_hr --docs

# Run tests only
dbt-run.sh test --select "marts.health"

# List models matching a selector
dbt-run.sh -- ls --select "staging.health" --output name
```

### `dbt-dry-run.sh`
Lists and compiles matched dbt models **without executing them**. Useful for previewing what a selector will affect and inspecting compiled SQL before running.

```bash
dbt-dry-run.sh [OPTIONS]
```

**Options:**
- `-s / --select <selector>` — dbt node selector (default: `staging.health marts.health`)
- `-e / --exclude <selector>` — exclude nodes
- `--full-refresh` — compile incrementals as full table replacements
- `--show-sql` — print compiled SQL for each matched model

**Examples:**
```bash
# Preview all health models
dbt-dry-run.sh

# Inspect compiled SQL for a single model
dbt-dry-run.sh -s fct_resting_hr --show-sql

# Preview a full-refresh (shows full INSERT vs. merge SQL)
dbt-dry-run.sh -s "marts.health" --full-refresh --show-sql
```

---

## Environment Management

### `inject-env.sh`
Pulls secrets from 1Password via `op` service account and injects them into runtime env files. Run this to regenerate `/opt/config/runtime/` env files after secret rotation.

### `env-inject.py`
Python utility that resolves a `.env` template (with `op://` references) into a concrete env file using `python-dotenv`.

```bash
python env-inject.py <template> <output> <env-file>
```

### `rebuild_env_from_containers.sh`
Reconstructs an env file from the environment of one or more running containers. Useful for recovering a lost `.env` from a running stack. Later containers override earlier ones for duplicate keys.

```bash
rebuild_env_from_containers.sh /path/to/output.env <container1> [container2 ...]
```

**Example:**
```bash
rebuild_env_from_containers.sh /opt/config/.env.recovered postgres airflow-webserver airflow-worker
```

### `rebuild_env_split_stack.sh`
Like `rebuild_env_from_containers.sh` but splits output across two env files (e.g. core vs. a secondary stack), with optional deduplication between them.

```bash
rebuild_env_split_stack.sh \
  --core-out  /opt/config/.env.core.recovered \
  --core      postgres nginx airflow-webserver airflow-worker \
  --manor-out /opt/config/.env.manor.recovered \
  --manor     manor-web manor-api \
  --dedupe manor
```

---

## Infrastructure Setup

### `ensure-minio-buckets.sh`
Idempotently creates required MinIO buckets. Safe to re-run; waits for MinIO to be healthy before proceeding.

```bash
ensure-minio-buckets.sh /path/to/.env.runtime
```

### `ensure-mlflow-prereqs.sh`
Ensures the MLflow Postgres database and MinIO bucket exist before MLflow starts. Run once during initial stack setup or after a database reset.

```bash
ensure-mlflow-prereqs.sh /path/to/.env.runtime
```

### `ensure-superset.sh`
Runs `superset db upgrade` inside the Superset container to apply any pending migrations.

```bash
ensure-superset.sh /path/to/.env
```

### `create-dk-ingest-folders.sh`
Creates the DraftKings data ingest directory structure under `/opt/ppd/inbox`, `/opt/ppd/archive`, and `/opt/ppd/error`.

### `migrate-minio-health-data.sh`
One-time migration script that reorganises health data files in MinIO from a flat per-category layout into a person-scoped layout (`{category}/json/{person}/`).

```bash
migrate-minio-health-data.sh /path/to/.env.runtime [person]
# DRY_RUN=true migrate-minio-health-data.sh /path/to/.env.runtime  # preview only
```

### `meshnet_enable.sh`
Enables NordVPN Meshnet on the host.
