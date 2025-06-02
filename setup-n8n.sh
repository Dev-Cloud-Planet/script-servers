#!/bin/bash

set -e

echo "🚀 Bienvenido al instalador de n8n con Docker + SSL automático (Let's Encrypt)"
echo "🌐 Primero, actualizaremos el sistema e instalaremos Docker y Docker Compose..."

# Actualizar sistema e instalar Docker si no está instalado
if ! command -v docker &> /dev/null; then
  echo "🛠 Docker no está instalado. Procediendo con la instalación..."

  sudo apt-get update -y
  sudo apt-get upgrade -y

  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  echo "Agregando usuario actual al grupo docker para evitar usar sudo..."
  sudo usermod -aG docker $USER

  echo "Docker y Docker Compose instalados. Es recomendable cerrar sesión y volver a entrar para aplicar permisos."
else
  echo "✅ Docker ya está instalado. Continuando..."
fi

# Validar Docker Compose instalado
if ! docker compose version &> /dev/null; then
  echo "❌ Docker Compose no está instalado. Por favor, instala docker-compose o docker compose."
  exit 1
fi

echo "🌐 Vamos a configurar tu entorno paso a paso. Responde las siguientes preguntas:"

# Preguntas al usuario
read -p "🟡 ¿Qué dominio o subdominio quieres usar para n8n (ej: n8n.tudominio.com)? " DOMAIN
read -p "📧 Correo para Let's Encrypt (certificados SSL): " EMAIL
read -p "🌍 Zona horaria del sistema (ej: America/Mexico_City): " TZ
read -p "🔐 Contraseña para PostgreSQL (usuario postgres): " POSTGRES_PASSWORD
read -p "👤 Usuario para acceso a n8n: " N8N_BASIC_AUTH_USER
read -p "🔑 Contraseña para acceso a n8n: " N8N_BASIC_AUTH_PASSWORD
read -p "🧪 Clave secreta para cifrar datos en n8n (N8N_ENCRYPTION_KEY): " N8N_ENCRYPTION_KEY
read -p "🔁 ¿Cuántos workers de n8n quieres usar? (1-5): " N8N_WORKERS

# Validación básica de workers
if ! [[ "$N8N_WORKERS" =~ ^[1-5]$ ]]; then
  echo "❌ Número inválido. Debes elegir entre 1 y 5 workers."
  exit 1
fi

# Crear archivo .env
cat > .env <<EOF
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

# Crear docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: "3.8"

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
    labels:
      - "traefik.enable=false"
      - "com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=false"
    expose:
      - "8081"
    networks:
      - backend
      - proxy

  pgadmin:
    image: dpage/pgadmin4
    container_name: pgadmin
    environment:
      - PGADMIN_DEFAULT_EMAIL=${EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${POSTGRES_PASSWORD}
    labels:
      - "traefik.enable=false"
      - "com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy=false"
    expose:
      - "80"
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

EOF

# Agregar workers dinámicamente
for i in $(seq 1 $N8N_WORKERS); do
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

# Agregar redes y volúmenes
cat >> docker-compose.yml <<EOF
volumes:
  postgres_data:
  n8n_data:

networks:
  proxy:
  backend:
EOF

echo "✅ docker-compose.yml generado correctamente."
echo "🔁 Levantando servicios..."
docker compose up -d

echo "🎉 Todo listo. Accede a tu instancia en: https://${DOMAIN}"
