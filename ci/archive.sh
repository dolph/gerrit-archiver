#!/bin/bash
set -ex

SSH_PUBLIC_KEY=$1
SSH_PRIVATE_KEY_BODY=$2
SSH_USERNAME=${3:-$USER}
RACK_USERNAME=$4
RACK_API_KEY=$5
RACK_REGION=$6
RACK_CONTAINER=$7

BATCH_SIZE=50

# Drop the public key into place.
mkdir -p ~/.ssh/
touch ~/.ssh/id_rsa.pub
chmod 0644 ~/.ssh/id_rsa.pub
echo $SSH_PUBLIC_KEY > ~/.ssh/id_rsa.pub

# This is really screwy, but something about the way Concourse CI handles line
# breaks from YML files causes them to be replaced by spaces by the time we get
# here, so we have to manually fix things up.
touch ~/.ssh/id_rsa
chmod 0600 ~/.ssh/id_rsa
echo '-----BEGIN RSA PRIVATE KEY-----' > ~/.ssh/id_rsa
echo $SSH_PRIVATE_KEY_BODY | tr " " "\n" >> ~/.ssh/id_rsa
echo '-----END RSA PRIVATE KEY-----' >> ~/.ssh/id_rsa

apt-get update
apt-get install -y \
    python \
    curl \
    ssh \
    ;

# Collect the server's identity.
touch ~/.ssh/known_hosts
chmod 0600 ~/.ssh/known_hosts
ssh-keyscan -p 29418 review.openstack.org >> ~/.ssh/known_hosts

# Note the start time.
echo "Start time: `date`"

# Find a relatively high review number. This is not guaranteed to get us the
# most newest review, but it's likely that the most recent review will be
# included.
max=`ssh -p 29418 $SSH_USERNAME@review.openstack.org gerrit query limit:50 | grep "  number: " | sed -e 's/^  number: //' | sort | tail -1`
re='^[0-9]+$'
if ! [[ $max =~ $re ]] ; then
    echo "Invalid max review value: $max"
    exit 1
fi

# Iterate through all reviews, from 1 to our max.
counter=0
for iteration in `seq 0 $(($max / $BATCH_SIZE + 1))`;
do
    skip_reviews=$(($iteration * $BATCH_SIZE))

    # Re-auth for each batch.
    curl \
        --silent \
        --request POST \
        https://identity.api.rackspacecloud.com/v2.0/tokens \
        --header "Content-type: application/json" \
        --data "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$RACK_USERNAME\",\"apiKey\":\"$RACK_API_KEY\"}}}" \
        > auth_response.json
    TOKEN=`python -c "import json; d = json.loads(open('auth_response.json', 'r').read()); print(d['access']['token']['id']);"`
    ENDPOINT=`python -c "import json; d = json.loads(open('auth_response.json', 'r').read()); endpoints = [x['endpoints'] for x in d['access']['serviceCatalog'] if x['type'] == 'object-store'].pop(); print([x['publicURL'] for x in endpoints if x['region'] == '$RACK_REGION'].pop());"`

    # Get as much information about the review as we can.
    for i in `seq 1 3`;
    do
        ssh -p 29418 $SSH_USERNAME@review.openstack.org gerrit query \
            --format JSON \
            --all-approvals \
            --all-reviewers \
            --comments \
            --current-patch-set \
            --dependencies \
            --files \
            --patch-sets \
            --submit-records \
            -S $skip_reviews \
            limit:$BATCH_SIZE \
            > tmp \
            && break || sleep 15
    done

    # Prune off the last line of the output, which is just paging data.
    sed -i '$ d' tmp

    # Create a directory to upload files from.
    mkdir reviews

    while IFS='' read -r line || [[ -n "$line" ]]; do
        review_number=`echo $line | python -c "import sys, json; print(json.loads(sys.stdin.read())['number'])"`

        # Write JSON to file for upload.
        echo $line > reviews/$review_number
    done < tmp

    # Clean up tmp file.
    rm -rf tmp

    # Upload to CDN.
    for f in reviews/*;
    do
        for i in `seq 1 3`;
        do
            curl \
                --silent \
                --request PUT \
                $ENDPOINT/$RACK_CONTAINER/`basename $f` \
                --header "X-Auth-Token: $TOKEN" \
                --header "Content-Type: application/json" \
                --upload-file $f \
                && break
        done
    done

    # Clean up upload directory.
    rm -rf reviews

    counter=$(($counter + $BATCH_SIZE))
    echo -ne "$counter / $max\r"
done

# Note the end time.
echo "End time: `date`"
