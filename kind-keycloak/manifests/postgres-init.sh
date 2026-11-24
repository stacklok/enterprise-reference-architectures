#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Creates the roles and databases SEP's Registry Server and Enterprise Manager
# use, with the role passwords in the kind-keycloak-db-roles Secret. It runs as
# the Postgres container's init script, once, on an empty data volume.
(
set -euo pipefail
run() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "$@"; }

run --dbname "${PGDATABASE:-postgres}" \
  -v db_app="$DB_APP_PASSWORD" -v db_migrator="$DB_MIGRATOR_PASSWORD" \
  -v em_app="$EM_APP_PASSWORD" -v em_migrator="$EM_MIGRATOR_PASSWORD" -v em_admin="$EM_ADMIN_PASSWORD" <<'SQL'
-- em_admin bypasses row-level security, and only a role that holds
-- BYPASSRLS (or a superuser) may grant it.
DO $$
BEGIN
  IF NOT (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'kind-keycloak: PostgreSQL user % needs BYPASSRLS (or superuser) to create Enterprise Manager''s admin role', current_user;
  END IF;
END
$$;
SELECT 'CREATE ROLE toolhive_registry_server'
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'toolhive_registry_server') \gexec
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['db_app','db_migrator','em_app','em_migrator','em_admin']) r
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE db_app LOGIN PASSWORD :'db_app';
ALTER ROLE db_migrator LOGIN PASSWORD :'db_migrator';
ALTER ROLE em_app LOGIN PASSWORD :'em_app';
ALTER ROLE em_migrator LOGIN CREATEROLE PASSWORD :'em_migrator';
ALTER ROLE em_admin LOGIN BYPASSRLS PASSWORD :'em_admin';
GRANT toolhive_registry_server TO db_app, db_migrator;
-- CREATE DATABASE ... OWNER needs the creator to be able to act as the owner,
-- which a non-superuser admin cannot until it holds the role.
GRANT em_migrator TO CURRENT_USER;
SELECT 'CREATE DATABASE registry'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'registry') \gexec
SELECT 'CREATE DATABASE enterprise_manager OWNER em_migrator'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'enterprise_manager') \gexec
GRANT CONNECT ON DATABASE registry TO db_app;
GRANT ALL PRIVILEGES ON DATABASE registry TO db_migrator;
SQL

run --dbname registry <<'SQL'
GRANT USAGE ON SCHEMA public TO db_app;
GRANT ALL PRIVILEGES ON SCHEMA public TO db_migrator;
SQL
)
