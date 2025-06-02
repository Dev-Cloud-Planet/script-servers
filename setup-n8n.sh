#!/bin/bash

set -euo pipefail

# Solicita la contraseña sudo al principio para evitar múltiples prompts
sudo -v

# Mantiene sudo activo mientras corre el script
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &

echo "🚀 Bienvenido al instalador de n8n con Docker + SSL automático (Let's Encrypt)"
echo "🌐 Actualizando tu sistema..."

sudo apt-get update -y && sudo apt-get upgrade -y

echo "🔍 Verificando si Docker está instalado..."

if command -v docker &> /dev/null && docker --version &> /dev/null; then
  echo "✅ Docker ya está instalado. Saltando instalación..."
else
  echo "🛠 Docker no está instalado. Procediendo con la instalación..."

  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  echo "✅ Docker instalado correctamente."

  echo "👤 Agregando tu usuario al grupo 'docker'..."
  sudo usermod -aG docker $USER

  echo "⚠️ Para aplicar los permisos, es necesario cerrar sesión y volver a entrar o reiniciar la máquina."
  echo "👉 Puedes hacerlo ahora o después, pero recuerda que sin esto tendrás que usar sudo para Docker."
fi

echo "🔍 Verificando que Docker Compose esté disponible..."

if command -v docker-compose &> /dev/null; then
  echo "✅ docker-compose (clásico) está instalado."
elif docker compose version &> /dev/null; then
  echo "✅ docker compose (nuevo plugin) está disponible."
else
  echo "❌ Docker Compose no está instalado. Procediendo a instalarlo..."

  sudo apt-get install -y docker-compose-plugin

  if docker compose version &> /dev/null; then
    echo "✅ docker compose (plugin) instalado correctamente."
  else
    echo "❌ No se pudo instalar Docker Compose. Abortando..."
    exit 1
  fi
fi

echo "📝 Configuraremos tu entorno. Responde lo siguiente:"

# Preguntas al usuario
read -rp "🟡 Dominio para n8n (ej: n8n.tudominio.com): " DOMAIN
read -rp "📧 Correo para Let's Encrypt: " EMAIL
read -rp "🌍 Zona horaria del sistema (ej: America/Mexico_City): " TZ
read -rsp "🔐 Contraseña para PostgreSQL: " POSTGRES_PASSWORD; echo
read -rp "👤 Usuario para acceso a n8n: " N8N_BASIC_AUTH_USER
read -rsp "🔑 Contraseña para n8n: " N8N_BASIC_AUTH_PASSWORD; echo
read -rsp "🧪 Clave secreta para cifrado en n8n: " N8N_ENCRYPTION_KEY; echo
read -rp "🔁 ¿Cuántos workers de n8n quieres usar? (1-5): " N8N_WORKERS

# Validación
if ! [[ "$N8N_WORKERS" =~ ^[1-5]$ ]]; then
  echo "❌ Número inválido de workers. Debes elegir entre 1 y 5."
  exit 1
fi

# Verificar permisos antes de crear .env
if [ -f .env ]; then
  echo "⚠️ El archivo .env ya existe. ¿Deseas sobrescribirlo? (s/n)"
  read -r confirm
  if [[ "$confirm" != "s" ]]; then
    echo "❌ Operación cancelada por el usuario."
    exit 1
  fi
fi

# Crear archivo .env de forma segura
echo "🔧 Generando archivo .env..."
tee .env > /dev/null <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
TZ=$TZ
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_WORKERS=$N8N_WORKERS
EOF

echo "✅ Archivo .env generado correctamente."

# Crear docker-compose.yml base
echo "📦 Generando archivo docker-compose.yml..."

tee docker-compose.yml > /dev/null <<'EOF'

services:
  nginx-proxy:
    image: jwilder/nginx-proxy
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - ./data/certs:/etc/nginx/certs:ro
      - ./data/vhost.d:/etc/nginx/vhost.d
      - ./data/html:/usr/share/nginx/html
      - ./data/conf.d:/etc/nginx/conf.d
    networks:
      - proxy

  letsencrypt:
    image: jrcs/letsencrypt-nginx-proxy-companion
    container_name: letsencrypt
    depends_on:
      - nginx-proxy
    environment:
      - NGINX_PROXY_CONTAINER=nginx-proxy
      - DEFAULT_EMAIL=${EMAIL}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./data/certs:/etc/nginx/certs:rw
      - ./data/vhost.d:/etc/nginx/vhost.d
      - ./data/html:/usr/share/nginx/html
    networks:
      - proxy

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

  redis-commander:
    image: rediscommander/redis-commander:latest
    container_name: redis-commander
    environment:
      - REDIS_HOSTS=local:redis:6379
      - TZ=${TZ}
    expose:
      - "8081"
    labels:
      - "traefik.enable=false"
      - "com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=false"
    networks:
      - backend
      - proxy

  pgadmin:
    image: dpage/pgadmin4
    container_name: pgadmin
    environment:
      - PGADMIN_DEFAULT_EMAIL=${EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${POSTGRES_PASSWORD}
    expose:
      - "80"
    labels:
      - "traefik.enable=false"
      - "com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=false"
    networks:
      - backend
      - proxy

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-main
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
      - WEBHOOK_TUNNEL_URL=https://${DOMAIN}
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - TZ=${TZ}
      - VIRTUAL_HOST=${DOMAIN}
      - VIRTUAL_PORT=5678
      - LETSENCRYPT_HOST=${DOMAIN}
      - LETSENCRYPT_EMAIL=${EMAIL}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - backend
      - proxy
  volumes:
    postgres_data:
    n8n_data:

  networks:
    proxy:
    backend:
EOF

# Añadir workers dinámicamente
for i in $(seq 1 "$N8N_WORKERS"); do
tee -a docker-compose.yml > /dev/null <<EOF

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
      - TZ=${TZ}
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
    networks:
      - backend
EOF
done

echo "✅ docker-compose.yml + workers generado correctamente."
echo "📦 Iniciando contenedores..."

docker compose up -d

echo "🎉 ¡Todo listo! Accede a tu instancia de n8n en: https://${DOMAIN}"

