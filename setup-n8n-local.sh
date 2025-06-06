#!/bin/bash

set -euo pipefail

# Solicita la contraseña sudo al principio para evitar múltiples prompts
sudo -v

# Mantiene sudo activo mientras corre el script
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &

echo "🚀 Bienvenido al instalador de n8n con Docker en local"
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

echo "🔧 Verificando si Docker Compose CLI plugin está instalado..."

if docker compose version &> /dev/null; then
  echo "✅ docker compose (plugin) ya está instalado."
else
  echo "🛠 Instalando docker-compose plugin..."

  sudo apt-get update -y
  sudo apt-get install -y docker-compose-plugin

  if docker compose version &> /dev/null; then
    echo "✅ docker compose (plugin) instalado correctamente."
  else
    echo "❌ No se pudo instalar docker compose (plugin). Abortando..."
    exit 1
  fi
fi

echo "🔧 Verificando si docker-compose (clásico) está instalado..."

if command -v docker-compose &> /dev/null; then
  echo "✅ docker-compose (clásico) está instalado."
else
  echo "🛠 Instalando docker-compose (clásico)..."

  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose

  if command -v docker-compose &> /dev/null; then
    echo "✅ docker-compose (clásico) instalado correctamente."
  else
    echo "❌ No se pudo instalar docker-compose (clásico). Abortando..."
    exit 1
  fi
fi

echo "Por favor ingrese los datos cuidadosamente"
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

# Crear archivo .env de forma segura
echo "🔧 Generando archivo .env..."
sudo bash -c "cat > .env <<EOF
TZ=$TZ
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_WORKERS=$N8N_WORKERS
EOF"

echo "✅ Archivo .env generado correctamente."

# Crear docker-compose.yml base
echo "📦 Generando archivo docker-compose.yml..."
sudo bash -c "cat > docker-compose.yml <<EOF
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

volumes:
  postgres_data:

networks:
  backend:

EOF"

# Agregar workers si el usuario lo solicitó
if [[ "$N8N_WORKERS" -gt 0 ]]; then
  for i in $(seq 1 "$N8N_WORKERS"); do
    sudo bash -c "cat >> docker-compose.yml <<EOF
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

EOF"
  done
fi

echo "✅ docker-compose.yml generado correctamente."
echo "🔁 Levantando servicios..."
sudo docker compose -f $(pwd)/docker-compose.yml up -d

echo "🎉 Todo listo. Accede a tu instancia en: https://${DOMAIN}"
echo "AQUI LOS CONTENEDORES"
sudo    docker ps 