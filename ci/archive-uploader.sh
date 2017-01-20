#!/bin/bash
set -e

ENDPOINT=$1
RACK_CONTAINER=$2
TOKEN=$3
f=$4

for i in `seq 1 3`;
do
    curl \
        --silent \
        --request PUT \
        $ENDPOINT/$RACK_CONTAINER/`basename $f` \
        --header "X-Auth-Token: $TOKEN" \
        --header "Content-Type: application/json" \
        --upload-file $f \
        && break || sleep 1
done
