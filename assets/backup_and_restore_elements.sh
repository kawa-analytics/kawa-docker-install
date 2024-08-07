set -e
#
# BACKUP and RESTORE the postgres database
# (Find out the name of your postgres container by running sudo docker ps)
#
DOCKER_CONTAINER_NAME=***
PATH_TO_DUMPS=/tmp


# ==================
# Dump the database
# ==================
DUMP_FILE_NAME=$PATH_TO_DUMPS/kawa-db-$(date +%Y-%m-%d).sql
sudo docker exec $DOCKER_CONTAINER_NAME pg_dump -U kawa postgres  > $DUMP_FILE_NAME


# =====================
# Restore the database
# =====================
DUMP_TO_RESTORE=$DUMP_FILE_NAME

sudo docker cp $DUMP_TO_RESTORE $DOCKER_CONTAINER_NAME:/tmp/db.sql

# shell into container
sudo docker exec -it $DOCKER_CONTAINER_NAME bash

# restore it from within
psql -U kawa -d postgres -c 'ALTER SCHEMA kawa RENAME TO kawa_old'
psql -U kawa -d postgres < /tmp/db.sql

## MANUAL CHECK REQURIED
## (alternative 1) IF ALL OK
## When the restore is correct: drop the tmp schema
psql -U kawa -d postgres -c 'DROP SCHEMA kawa_old CASCADE'


## (alternative 2) IF SOME PROBLEM WAS ENCOUNTERED: REVERT THE RESTORE
psql -U kawa -d postgres -c 'DROP SCHEMA IF EXISTS kawa CASCADE'
psql -U kawa -d postgres -c 'ALTER SCHEMA kawa_old RENAME TO kawa'