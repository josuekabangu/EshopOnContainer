#!/bin/bash
set -e

echo "Waiting for PostgreSQL to start..."
until pg_isready -U postgres -d catalogdb; do
  sleep 1
done

echo "Creating vector extension in catalogdb..."
psql -U postgres -d catalogdb -c "CREATE EXTENSION IF NOT EXISTS vector;"

echo "Creating identitydb if not exists..."
psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'identitydb'" | grep -q 1 || psql -U postgres -c "CREATE DATABASE identitydb;"

echo "Database identitydb created (if it wasn't already)."
