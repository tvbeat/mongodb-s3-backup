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

This script dumps the current mongo database, tars it, then sends it to an Amazon S3 bucket.

OPTIONS:
   -h      Show this message
   -u      Mongodb user
   -p      Mongodb password
   -k      AWS Access Key
   -s      AWS Secret Key
   -r      Amazon S3 region
   -b      Amazon S3 bucket name
EOF
}

MONGODB_USER=
MONGODB_PASSWORD=
AWS_ACCESS_KEY=
AWS_SECRET_KEY=
S3_REGION=
S3_BUCKET=

while getopts “ht:u:p:k:s:r:b:” OPTION
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
    ?)
      usage
      exit
    ;;
  esac
done

if [[ -z $MONGODB_USER ]] || [[ -z $MONGODB_PASSWORD ]] || [[ -z $AWS_ACCESS_KEY ]] || [[ -z $AWS_SECRET_KEY ]] || [[ -z $S3_REGION ]] || [[ -z $S3_BUCKET ]]
then
  usage
  exit 1
fi

# Get the directory the script is being run from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo $DIR
# Store the current date in YYYY-mm-DD-HHMMSS
DATE=$(date -u "+%F-%H%M%S")
FILE_NAME="backup-$DATE"
ARCHIVE_NAME="$FILE_NAME.tar.gz"

# Lock the database
# Note there is a bug in mongo 2.2.0 where you must touch all the databases before you run mongodump
mongo -username "$MONGODB_USER" -password "$MONGODB_PASSWORD" admin --eval "var databaseNames = db.getMongo().getDBNames(); for (var i in databaseNames) { printjson(db.getSiblingDB(databaseNames[i]).getCollectionNames()) }; printjson(db.fsyncLock());"

# Dump the database
mongodump -username "$MONGODB_USER" -password "$MONGODB_PASSWORD" --out $DIR/backup/$FILE_NAME

# Unlock the database
mongo -username "$MONGODB_USER" -password "$MONGODB_PASSWORD" admin --eval "printjson(db.fsyncUnlock());"

# Tar Gzip the file
tar -C $DIR/backup/ -zcvf $DIR/backup/$ARCHIVE_NAME $FILE_NAME/

# Remove the backup directory
rm -r $DIR/backup/$FILE_NAME

# Send the file to the backup drive or S3

cd $DIR/backup

hmac="openssl dgst -binary -sha256 -mac HMAC -macopt hexkey:"
hexdump="xxd -p -c 256"

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
CANONICAL_REQ="echo -e -n "PUT\\n/$ARCHIVE_NAME\\n\\ndate:$DATE_HEADER\\nhost:$S3_BUCKET.s3.amazonaws.com\\nx-amz-acl:public-read\\nx-amz-content-sha256:$FILE_HASH\\nx-amz-date:$DATE_ISO\\n\\n$HEADERS\\n$FILE_HASH""
CANONICAL_REQ_HASH=$($CANONICAL_REQ | shasum -a 256 | awk '{ print $1 }')
SIGN="echo -e -n "AWS4-HMAC-SHA256\\n$DATE_ISO\\n$DATE_SHORT/$S3_REGION/s3/aws4_request\\n$CANONICAL_REQ_HASH""
SIGNATURE=$($SIGN | $hmac$SIGKEY | $hexdump )

echo -e -n "AWS HTTP Response code: "

curl -s -o /dev/null -w "%{http_code}" \
  -T "$ARCHIVE_NAME" \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=$AWS_ACCESS_KEY/$DATE_SHORT/$S3_REGION/s3/aws4_request,SignedHeaders=$HEADERS,Signature=$SIGNATURE" \
  -H "Date: $DATE_HEADER" \
  -H "x-amz-acl: public-read" \
  -H "x-amz-content-sha256: $FILE_HASH" \
  -H "x-amz-date: $DATE_ISO" \
  "https://$S3_BUCKET.s3.amazonaws.com/$ARCHIVE_NAME"

echo ""

# Remove the tarball
rm $ARCHIVE_NAME
