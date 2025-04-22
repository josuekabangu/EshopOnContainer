#!/bin/bash
set -e
echo "Waiting for PostgreSQL to start..."
until pg_isready -U postgres -d catalogdb; do
  sleep 1
done
echo "Creating vector extension..."
psql -U postgres -d catalogdb -c "CREATE EXTENSION IF NOT EXISTS vector;"
