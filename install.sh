#!/bin/bash
set -e

interactive="true"
branch="1.25.x"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --interactive=*) interactive="${1#*=}" ;;
        --branch=*) branch="${1#*=}" ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Perform docker login
CREDENTIALS_FILE=./assets/kawa-registry.credentials
DOCKER_IMAGE_REGISTRY_URL="registry.gitlab.com/kawa-analytics-dev"
DOCKER_TOKEN_USERNAME=$(cat $CREDENTIALS_FILE | head -1)
DOCKER_TOKEN_PASSWORD=$(cat $CREDENTIALS_FILE | tail -n -1)
echo "$DOCKER_TOKEN_PASSWORD"  | docker login $DOCKER_IMAGE_REGISTRY_URL -u "$DOCKER_TOKEN_USERNAME" --password-stdin

# Create a KAWA system user. The UID matches the kawa user inside the kawa server.
KAWA_UID=5000
KAWA_GID=5000
KAWA_USER=$KAWA_UID:$KAWA_GID

# Generate secrets
KAWA_MASTER_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
KAWA_DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
KAWA_HASHED_DB_PASSWORD=$(echo -n "$KAWA_DB_PASSWORD" | shasum -a 256 | cut -d ' ' -f 1)
KAWA_RUNNER_AES_KEY=$(head /dev/urandom | shasum -a 256 | cut -d ' ' -f 1)

# Generate the key files
# They will be mounted in docker compose secrets and consumed by kawa
echo "$KAWA_RUNNER_AES_KEY" > kawa.runner.key
echo "$KAWA_DB_PASSWORD" > db.password
echo "$KAWA_MASTER_KEY" > kawa.master.key
chown "$KAWA_USER" db.password kawa.master.key kawa.runner.key
chmod 600 db.password kawa.master.key kawa.runner.key

# Update the clickhouse user override file
# It accepts the sha256 of the password.
sed -i "s/.*password_sha256.*/<password_sha256_hex>$KAWA_HASHED_DB_PASSWORD<\/password_sha256_hex>/g" ./assets/users.d/kawa.xml

# Configure SMTP
touch ./smtp.credentials
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to setup a connection with a SMTP server? Y/[N] " SETUP_SMTP
  if [ "$SETUP_SMTP" == 'Y' ] || [ "$SETUP_SMTP" == 'y' ]; then

    read -r -p "Please specify the username to connect to your SMTP server: " SMTP_USERNAME
    read -r -p "Please specify the password to connect to your SMTP server: " SMTP_PASSWORD

    echo "$SMTP_USERNAME $SMTP_PASSWORD" > ./smtp.credentials
  fi
fi

# Regardless if SMTP was configured or not, the file exists
chown $KAWA_USER ./smtp.credentials
chmod 600 ./smtp.credentials

# Copy Docker compose template
DOCKER_COMPOSE_FILE=./docker-compose.yml
cp ./assets/docker-compose-template.yml $DOCKER_COMPOSE_FILE

sed -i "s/\${branch}/$branch/g" $DOCKER_COMPOSE_FILE

# Configure OpenID/Oauth2 Secret
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to setup SSO (OpenID Connect/OAuth2) Y/[N] " SETUP_OAUTH2
  if [ "$SETUP_OAUTH2" == 'Y' ] || [ "$SETUP_OAUTH2" == 'y' ]; then
    read -r -p "Please specify the client secret for your application: " CLIENT_SECRET
    sed -i "s|_OAUTH2_CLIENT_SECRET_|$CLIENT_SECRET|g" $DOCKER_COMPOSE_FILE
  else
    sed -i "s|_OAUTH2_CLIENT_SECRET_|NA|g" $DOCKER_COMPOSE_FILE
  fi
else
  sed -i "s|_OAUTH2_CLIENT_SECRET_|NA|g" $DOCKER_COMPOSE_FILE
fi

# Configure SSL
if [ "$interactive" == "true" ]; then
  read -p "Do you want to use HTTPS to connect to KAWA? Y/[N] " USE_SSL
  if [ "$USE_SSL" == 'Y' ] || [ "$USE_SSL" == 'y' ]; then

    read -p "Please specify the path to your certificate file: " PATH_TO_CRT_FILE
    read -p "Please specify the path to your server private key: " PATH_TO_PRIVATE_KEY_FILE

    cp $PATH_TO_CRT_FILE ./server.crt
    cp $PATH_TO_PRIVATE_KEY_FILE ./server.key

    chown $KAWA_USER ./server.crt ./server.key
    chmod 600 ./server.crt ./server.key

    # Turns on HTTPS
    sed -i 's/_USE_HTTPS_/true/g' $DOCKER_COMPOSE_FILE
    sed -i 's|_KAWA_URL_|https://kawa-server:8080|g' $DOCKER_COMPOSE_FILE

  else
    # Turns off HTTPS and remove unnecessary entries in docker compose file
    sed -i 's/_USE_HTTPS_/false/g' $DOCKER_COMPOSE_FILE
    sed -i 's|_KAWA_URL_|http://kawa-server:8080|g' $DOCKER_COMPOSE_FILE

    sed -i '/.*KAWA_PATH_TO_SERVER_CERTIFICATE.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*KAWA_PATH_TO_SERVER_PRIVATE_KEY.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/\s*file: server\.key/d' $DOCKER_COMPOSE_FILE
    sed -i '/\s*file: server\.crt/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*server-private-key.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*server-certificate.*/d' $DOCKER_COMPOSE_FILE
  fi
else
    # Turns off HTTPS and remove unnecessary entries in docker compose file
    sed -i 's/_USE_HTTPS_/false/g' $DOCKER_COMPOSE_FILE
    sed -i 's|_KAWA_URL_|http://kawa-server:8080|g' $DOCKER_COMPOSE_FILE

    sed -i '/.*KAWA_PATH_TO_SERVER_CERTIFICATE.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*KAWA_PATH_TO_SERVER_PRIVATE_KEY.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/\s*file: server\.key/d' $DOCKER_COMPOSE_FILE
    sed -i '/\s*file: server\.crt/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*server-private-key.*/d' $DOCKER_COMPOSE_FILE
    sed -i '/.*server-certificate.*/d' $DOCKER_COMPOSE_FILE
fi

# Configure the data directory
# This will serve as mout point for all the docker compose volumes,
# Clickhouse data, Postgres data and Kawa data
if [ "$interactive" == "true" ]; then
  read -r -p "Please specify the directory where you want to persist your data (will be created if it does not exist): " MOUNT_DIRECTORY
  mkdir -p "$MOUNT_DIRECTORY"/pgdata "$MOUNT_DIRECTORY"/clickhousedata "$MOUNT_DIRECTORY"/kawadata
  sed -i "s|_MOUNT_DIRECTORY_|$MOUNT_DIRECTORY|g" $DOCKER_COMPOSE_FILE
else
  MOUNT_DIRECTORY="./data"
  mkdir -p $MOUNT_DIRECTORY/pgdata $MOUNT_DIRECTORY/clickhousedata $MOUNT_DIRECTORY/kawadata
  sed -i "s|_MOUNT_DIRECTORY_|$MOUNT_DIRECTORY|g" $DOCKER_COMPOSE_FILE
fi

echo "Installation complete. To start the server, run: sudo docker compose up -d."