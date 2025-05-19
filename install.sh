#!/bin/bash
set -e

interactive="true"
KAWA_BRANCH_NAME=""
SKIP_DOCKER_LOGIN="false"
ENV_FILE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --interactive=*) interactive="${1#*=}" ;;
        --version=*) KAWA_BRANCH_NAME="${1#*=}" ;;
        --skip-docker-login=*) SKIP_DOCKER_LOGIN="${1#*=}" ;;
        --env-file=*) ENV_FILE="${1#*=}" ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ -n "$ENV_FILE" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        echo "Sourcing environment variables from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
    else
        echo "Error: Specified .env file does not exist: $ENV_FILE"
        exit 1
    fi
fi

kawa_latest_version="1.30.x"

if [[ -z "$KAWA_BRANCH_NAME" ]]; then
    if [[ "$interactive" == "true" ]]; then
        read -r -p "Do you want the latest version? Y/[N] " use_latest_version
          if [ "$use_latest_version" == 'Y' ] || [ "$use_latest_version" == 'y' ]; then
              KAWA_BRANCH_NAME=$kawa_latest_version
          else
            read -r -p "Which version do you want to use? " KAWA_BRANCH_NAME
          fi
    else
      KAWA_BRANCH_NAME=$kawa_latest_version
    fi
fi

echo $KAWA_BRANCH_NAME

if [[ "$SKIP_DOCKER_LOGIN" != "true" ]]; then
    CREDENTIALS_FILE=./assets/kawa-registry.credentials
    DOCKER_TOKEN_USERNAME=$(head -1 "$CREDENTIALS_FILE")
    DOCKER_TOKEN_PASSWORD=$(tail -n -1 "$CREDENTIALS_FILE")
    echo "$DOCKER_TOKEN_PASSWORD" | docker login registry.gitlab.com -u "$DOCKER_TOKEN_USERNAME" --password-stdin
else
    echo "Skipping Docker login as --skip-docker-login=true is set."
fi

KAWA_OAUTH2_CLIENT_SECRET=NA
KAWA_SMTP_USERNAME=NA
KAWA_SMTP_PASSWORD=NA

# Configure warehouse
# Clickhouse or Snowflake
if [ "$interactive" == "true" ]; then
  read -r -p "Do you want to connect to an external snowflake warehouse? " USE_SNOWFLAKE
  if [ "$USE_SNOWFLAKE" == 'Y' ] || [ "$USE_SNOWFLAKE" == 'y' ]; then
      KAWA_WAREHOUSE_TYPE='SNOWFLAKE'
      read -r -p "Please specify the snowflake user (Read only): " KAWA_SNOWFLAKE_USER
      read -r -p "Please specify the snowflake password (Read only): " KAWA_SNOWFLAKE_PASSWORD
      read -r -p "Please specify the snowflake warehouse (Read only): " KAWA_SNOWFLAKE_WAREHOUSE
      read -r -p "Please specify the snowflake account (Read only): " KAWA_SNOWFLAKE_ACCOUNT


      read -r -p "Do you want to configure write back in Snowflake? " CONFIGURE_SNOWFLAKE_WRITE_BACK
      if [ "$CONFIGURE_SNOWFLAKE_WRITE_BACK" == 'Y' ] || [ "$CONFIGURE_SNOWFLAKE_WRITE_BACK" == 'y' ]; then
        read -r -p "Please specify the snowflake user (Read/Write): " KAWA_SNOWFLAKE_WRITER_USER
        read -r -p "Please specify the snowflake password (Read/Write): " KAWA_SNOWFLAKE_WRITER_PASSWORD
        read -r -p "Please specify the snowflake warehouse (Read/Write): " KAWA_SNOWFLAKE_WRITER_WAREHOUSE
        read -r -p "Please specify the snowflake account (Read/Write): " KAWA_SNOWFLAKE_WRITER_ACCOUNT
        read -r -p "Please specify the database where kawa will write (Must exist): " KAWA_SNOWFLAKE_WRITER_CATALOG
        read -r -p "Please specify the schema where kawa will write (Must exist): " KAWA_SNOWFLAKE_WRITER_SCHEMA
      fi    

  else
    KAWA_WAREHOUSE_TYPE='CLICKHOUSE'
  fi
fi


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
KAWA_SERVER_HTTPS=false
KAWA_SERVER_URL=http://${KAWA_SERVICE_NAME}

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

    KAWA_SERVER_HTTPS=true
    KAWA_SERVER_URL=https://${KAWA_SERVICE_NAME}
  else
    touch ./server.crt ./server.key
  fi
fi

# Update the clickhouse user override file, it accepts the sha256 of the password
KAWA_DB_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
kawa_hashed_db_password=$(echo -n "$KAWA_DB_PASSWORD" | sha256sum | cut -d ' ' -f 1)
sed -i "s/.*password_sha256.*/<password_sha256_hex>$kawa_hashed_db_password<\/password_sha256_hex>/g" ./assets/users.d/kawa.xml

master_key=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
kawa_clickhouse_db_name="default"

KAWA_DB_USER="kawa"
KAWA_RUNNER_AES_KEY=$(head /dev/urandom | sha256sum | cut -d ' ' -f 1)
KAWA_ENCRYPTION_KEY=$(echo -n "${master_key}-key" | sha256sum | awk '{print substr($1, 1, 24)}')
KAWA_ENCRYPTION_IV=$(echo -n "${master_key}-iv" | sha256sum | awk '{print substr($1, 1, 16)}')
KAWA_ACCESS_TOKEN_SECRET=$(head -c 64 /dev/urandom | xxd -p | tr -d '\n')
KAWA_REFRESH_TOKEN_SECRET=$(head -c 64 /dev/urandom | xxd -p | tr -d '\n')
KAWA_POSTGRES_JDBC_URL="jdbc:postgresql://postgres:5432/postgres?currentSchema=kawa&user=${KAWA_DB_USER}&password=${KAWA_DB_PASSWORD}"
KAWA_CLICKHOUSE_JDBC_URL="jdbc:clickhouse://clickhouse:8123/${kawa_clickhouse_db_name}?user=${KAWA_DB_USER}&password=${KAWA_DB_PASSWORD}"
KAWA_CLICKHOUSE_INTERNAL_DATABASE=$kawa_clickhouse_db_name
KAWA_DOCKER_COMPOSE_NETWORK_NAME=kawa-network-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

MOUNT_DIRECTORY="./data"
rm -rf "$MOUNT_DIRECTORY"

# Configure the data directory, that will serve as mount point for all the docker compose volumes
if [ "$interactive" == "true" ]; then
  read -r -p "Please specify the directory where you want to persist your data (will be created if it does not exist): " MOUNT_DIRECTORY
fi

mkdir -p "$MOUNT_DIRECTORY/pgdata" "$MOUNT_DIRECTORY/clickhousedata" "$MOUNT_DIRECTORY/kawadata" "$MOUNT_DIRECTORY/chromadbdata"

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
