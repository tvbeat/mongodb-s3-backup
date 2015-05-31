#!/bin/bash
#
# Argument = -u user -p password -k key -s secret -b bucket
#
# To Do - Add logging of output.
# To Do - Abstract bucket region to options

set -e

export PATH="$PATH:/usr/local/bin"

usage()
{
cat << EOF
usage: $0 options

This script dumps the mongo database, tars it, then sends it to an Amazon S3 bucket.

OPTIONS:
   -h      Show this message

MANDATORY:
   -k      AWS Access Key
   -s      AWS Secret Key
   -r      Amazon S3 region
   -b      Amazon S3 bucket name

OPTIONAL:
   -u      MongoDB user
   -p      MongoDB password
   -d      Specific database to backup
   -f      Bucket folder

EOF
}

while getopts “ht:u:p:d:k:s:r:b:f:” OPTION
do
  case $OPTION in
    h)
      usage
      exit 1
      ;;
    u)
      MONGODB_USER=$OPTARG
      ;;
    p)
      MONGODB_PASSWORD=$OPTARG
      ;;
    d)
      DATABASE=$OPTARG
      ;;
    k)
      AWS_ACCESS_KEY=$OPTARG
      ;;
    s)
      AWS_SECRET_KEY=$OPTARG
      ;;
    r)
      S3_REGION=$OPTARG
      ;;
    b)
      S3_BUCKET=$OPTARG
      ;;
    f)
      FOLDER=$OPTARG
      ;;
    ?)
      usage
      exit
      ;;
  esac
done

if [[ -z $AWS_ACCESS_KEY ]] || [[ -z $AWS_SECRET_KEY ]] || [[ -z $S3_REGION ]] || [[ -z $S3_BUCKET ]]
then
  usage
  exit 1
fi

# Get the directory the script is being run from
DIR="/tmp/mongodb_backup"
# Store the current date in YYYY-mm-DD-HHMMSS
DATE=$(date -u "+%F-%H%M%S")

# Lock the database
# Note there is a bug in mongo 2.2.0 where you must touch all the databases before you run mongodump
#mongo  admin --eval "var databaseNames = db.getMongo().getDBNames(); for (var i in databaseNames) { printjson(db.getSiblingDB(databaseNames[i]).getCollectionNames()) }; printjson(db.fsyncLock());"

# Dump the database

if [[ ! -z $DATABASE ]]
then
   FILE_NAME="$DATABASE-$DATE"
   if [[ ! -z $MONGODB_USER ]] && [[ ! -z $MONGODB_PASSWORD ]]
   then
      mongodump -username "$MONGODB_USER" -password "$MONGODB_PASSWORD" -db "$DATABASE" --out $DIR/$FILE_NAME
   else
      mongodump -db "$DATABASE" --out $DIR/$FILE_NAME
   fi
else
   FILE_NAME="$DATE"
   if [[ ! -z $MONGODB_USER ]] && [[ ! -z $MONGODB_PASSWORD ]]
   then
      mongodump -username "$MONGODB_USER" -password "$MONGODB_PASSWORD" --out $DIR/$FILE_NAME
   else
      mongodump --out $DIR/$FILE_NAME
   fi
fi

ARCHIVE_NAME="$FILE_NAME.tar.gz"

# Unlock the database
#mongo admin --eval "printjson(db.fsyncUnlock());"

# Tar Gzip the file
tar -C $DIR/ -zcvf $DIR/$ARCHIVE_NAME $FILE_NAME/
# Remove the backup directory
rm -r $DIR/$FILE_NAME

# Send the file to the backup drive or S3

cd $DIR

hmac="openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:"
hexdump="xxd -p -c 256"

PAYLOAD="$ARCHIVE_NAME"

if [[ ! -z $FOLDER ]]
then
 PAYLOAD="$FOLDER/$ARCHIVE_NAME"
fi

HEADERS="date;host;x-amz-acl;x-amz-content-sha256;x-amz-date"

DATE_ISO=$(date -u "+%Y%m%dT%H%M%SZ")
DATE_SHORT=$(date -u "+%Y%m%d")
DATE_HEADER=$(date -u "+%a, %d %h %Y %T %Z")


AWS_HMAC=$(echo -e -n AWS4$AWS_SECRET_KEY | $hexdump)
DATE_HMAC=$(echo -e -n $DATE_SHORT | $hmac$AWS_HMAC | $hexdump)
REGION_HMAC=$(echo -e -n $S3_REGION | $hmac$DATE_HMAC | $hexdump)
SERVICE_HMAC=$(echo -e -n "s3" | $hmac$REGION_HMAC | $hexdump)
SIGKEY=$(echo -e -n "aws4_request" | $hmac$SERVICE_HMAC | $hexdump)


FILE_HASH=$(shasum -ba 256 "$ARCHIVE_NAME" | awk '{ print $1 }')
CANONICAL_REQ="echo -e -n "PUT\\n/$PAYLOAD\\n\\ndate:$DATE_HEADER\\nhost:$S3_BUCKET.s3.amazonaws.com\\nx-amz-acl:private\\nx-amz-content-sha256:$FILE_HASH\\nx-amz-date:$DATE_ISO\\n\\n$HEADERS\\n$FILE_HASH""
CANONICAL_REQ_HASH=$($CANONICAL_REQ | shasum -a 256 | awk '{ print $1 }')
SIGN="echo -e -n "AWS4-HMAC-SHA256\\n$DATE_ISO\\n$DATE_SHORT/$S3_REGION/s3/aws4_request\\n$CANONICAL_REQ_HASH""
SIGNATURE=$($SIGN | $hmac$SIGKEY | $hexdump )

curl -s -o /dev/null -w "%{http_code}" \
  -T "$DIR/$ARCHIVE_NAME" \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=$AWS_ACCESS_KEY/$DATE_SHORT/$S3_REGION/s3/aws4_request,SignedHeaders=$HEADERS,Signature=$SIGNATURE" \
  -H "Date: $DATE_HEADER" \
  -H "x-amz-acl: private" \
  -H "x-amz-content-sha256: $FILE_HASH" \
  -H "x-amz-date: $DATE_ISO" \
  "https://$S3_BUCKET.s3.amazonaws.com/$PAYLOAD"

# Remove the tarball
echo ""
rm $ARCHIVE_NAME
