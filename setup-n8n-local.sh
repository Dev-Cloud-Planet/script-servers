#!/bin/bash

set -euo pipefail

echo "🚀 Instalador simplificado de n8n en localhost con PostgreSQL, Redis y Workers"

# Verifica Docker y Docker Compose
echo "🔍 Verificando Docker..."
if ! command -v docker &> /dev/null; then
  echo "❌ Docker no está instalado. Instálalo primero."
  exit 1
fi

echo "🔍 Verificando Docker Compose..."
if ! docker compose version &> /dev/null; then
  echo "❌ Docker Compose plugin no está instalado. Intenta con: sudo apt install docker-compose-plugin"
  exit 1
fi

# Preguntas básicas
read -rp "🌍 Zona horaria del sistema (ej: America/Mexico_City): " TZ
read -rsp "🔐 Contraseña para PostgreSQL: " POSTGRES_PASSWORD; echo
read -rp "👤 Usuario para acceso a n8n: " N8N_BASIC_AUTH_USER
read -rsp "🔑 Contraseña para n8n: " N8N_BASIC_AUTH_PASSWORD; echo
read -rsp "🧪 Clave secreta para cifrado en n8n: " N8N_ENCRYPTION_KEY; echo
read -rp "🔁 ¿Cuántos workers deseas lanzar? (0-5): " N8N_WORKERS

if ! [[ "$N8N_WORKERS" =~ ^[0-5]$ ]]; then
  echo "❌ Número de workers inválido (elige entre 0 y 5)"
  exit 1
fi

# Crear .env
cat > .env <<EOF
TZ=$TZ
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_WORKERS=$N8N_WORKERS
EOF

echo "✅ Archivo .env generado."

# Crear docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - backend

  redis:
    image: redis:7
    container_name: redis
    restart: always
    networks:
      - backend

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-main
    ports:
      - "5678:5678"
    restart: always
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=postgres
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - QUEUE_MODE=redis
      - QUEUE_REDIS_HOST=redis
      - GENERIC_TIMEZONE=${TZ}
    depends_on:
      - postgres
      - redis
    networks:
      - backend

EOF

# Agregar workers si el usuario lo solicitó
if [[ "$N8N_WORKERS" -gt 0 ]]; then
  for i in $(seq 1 "$N8N_WORKERS"); do
    cat >> docker-compose.yml <<EOF
  n8n-worker-$i:
    image: n8nio/n8n:latest
    container_name: n8n-worker-$i
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=postgres
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - QUEUE_MODE=redis
      - QUEUE_REDIS_HOST=redis
      - EXECUTIONS_MODE=queue
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - GENERIC_TIMEZONE=${TZ}
    depends_on:
      - postgres
      - redis
    networks:
      - backend

EOF
  done
fi

cat >> docker-compose.yml <<EOF
volumes:
  postgres_data:

networks:
  backend:
EOF

echo "✅ docker-compose.yml generado."

echo "🎉 Instalación lista. Ejecuta con: docker compose up -d"
