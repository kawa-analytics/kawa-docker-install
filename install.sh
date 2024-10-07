#!/bin/bash
set -e

interactive="true"
KAWA_BRANCH_NAME="develop"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --interactive=*) interactive="${1#*=}" ;;
        --branch=*) KAWA_BRANCH_NAME="${1#*=}" ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Perform docker login
CREDENTIALS_FILE=./assets/kawa-registry.credentials
DOCKER_TOKEN_USERNAME=$(cat $CREDENTIALS_FILE | head -1)
DOCKER_TOKEN_PASSWORD=$(cat $CREDENTIALS_FILE | tail -n -1)
echo "$DOCKER_TOKEN_PASSWORD"  | docker login registry.gitlab.com -u "$DOCKER_TOKEN_USERNAME" --password-stdin

KAWA_OAUTH2_CLIENT_SECRET=NA
KAWA_SMTP_USERNAME=NA
KAWA_SMTP_PASSWORD=NA

# Configure smtp
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to setup a connection with a SMTP server? Y/[N] " SETUP_SMTP
  if [ "$SETUP_SMTP" == 'Y' ] || [ "$SETUP_SMTP" == 'y' ]; then

    read -r -p "Please specify the username to connect to your SMTP server: " KAWA_SMTP_USERNAME
    read -r -p "Please specify the password to connect to your SMTP server: " KAWA_SMTP_PASSWORD
  fi
fi

# Configure OpenID/Oauth2 Secret
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to setup SSO (OpenID Connect/OAuth2) Y/[N] " SETUP_OAUTH2
  if [ "$SETUP_OAUTH2" == 'Y' ] || [ "$SETUP_OAUTH2" == 'y' ]; then
    read -r -p "Please specify the client secret for your application: " KAWA_OAUTH2_CLIENT_SECRET
  fi
fi

KAWA_SERVICE_NAME="kawa-server"
KAWA_HTTPS=false
KAWA_URL=http://${KAWA_SERVICE_NAME}:8080

kawa_user=5000:5000

# Configure SSL
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to use HTTPS to connect to KAWA? Y/[N] " USE_SSL
  
  if [ "$USE_SSL" == 'Y' ] || [ "$USE_SSL" == 'y' ]; then

    read -r -p "Please specify the path to your certificate file: " path_to_crt_file
    read -r -p "Please specify the path to your server private key: " path_to_private_key

    cp "$path_to_crt_file" ./server.crt
    cp "$path_to_private_key" ./server.key

    chown $kawa_user ./server.crt ./server.key
    chmod 600 ./server.crt ./server.key

    KAWA_HTTPS=true
    KAWA_URL=https://${KAWA_SERVICE_NAME}:8080
  else
    touch ./server.crt ./server.key
  fi
fi

# Update the clickhouse user override file, it accepts the sha256 of the password
KAWA_DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
kawa_hashed_db_password=$(echo -n "$KAWA_DB_PASSWORD" | shasum -a 256 | cut -d ' ' -f 1)
sed -i "s/.*password_sha256.*/<password_sha256_hex>$kawa_hashed_db_password<\/password_sha256_hex>/g" ./assets/users.d/kawa.xml

master_key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
kawa_clickhouse_db_name="default"

KAWA_DB_USER="kawa"
KAWA_RUNNER_AES_KEY=$(head /dev/urandom | shasum -a 256 | cut -d ' ' -f 1)
KAWA_ENCRYPTION_KEY=$(echo -n "${master_key}-key" | sha256sum | awk '{print substr($1, 1, 24)}')
KAWA_ENCRYPTION_IV=$(echo -n "${master_key}-iv" | sha256sum | awk '{print substr($1, 1, 16)}')
KAWA_ACCESS_TOKEN_SECRET=$(head -c 64 /dev/urandom | xxd -p | tr -d '\n')
KAWA_REFRESH_TOKEN_SECRET=$(head -c 64 /dev/urandom | xxd -p | tr -d '\n')
KAWA_POSTGRES_JDBC_URL="jdbc:postgresql://postgres:5432/postgres?currentSchema=kawa&user=${KAWA_DB_USER}&password=${KAWA_DB_PASSWORD}"
KAWA_CLICKHOUSE_JDBC_URL="jdbc:clickhouse://clickhouse:8123/${kawa_clickhouse_db_name}?user=${KAWA_DB_USER}&password=${KAWA_DB_PASSWORD}"
KAWA_CLICKHOUSE_INTERNAL_DATABASE=$kawa_clickhouse_db_name

MOUNT_DIRECTORY="./data"
rm -rf "$MOUNT_DIRECTORY"

# Configure the data directory, that will serve as mount point for all the docker compose volumes
if [ "$interactive" == "true" ]; then
  read -r -p "Please specify the directory where you want to persist your data (will be created if it does not exist): " MOUNT_DIRECTORY
fi

mkdir -p "$MOUNT_DIRECTORY/pgdata" "$MOUNT_DIRECTORY/clickhousedata" "$MOUNT_DIRECTORY/kawadata"

# If the environment variable is set, use it; otherwise, use the default from .env.defaults
> .env
while IFS='=' read -r var_name default_value || [[ -n "$var_name" ]]; do
  # Trim leading and trailing whitespace from the var_name (removes indentation)
  var_name="$(echo "$var_name" | xargs)"

  # Ignore lines that start with '#' after trimming or are completely empty
  if [[ "$var_name" =~ ^#.*$ || -z "$var_name" ]]; then
    continue
  fi

  # Handle empty value case where the key exists but no value is provided (e.g., KAWA_SMTP_PASSWORD=)
  value="${!var_name:-$default_value}"

  # Write the result to .env, even if the default_value is empty
  echo "$var_name=$value" >> .env
done < .env.defaults

echo "Installation complete. To start the server, run: sudo docker compose up -d."
