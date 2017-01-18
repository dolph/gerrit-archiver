#!/bin/bash
set -ex

SSH_PUBLIC_KEY=$1
SSH_PRIVATE_KEY_BODY=$2
RACK_USERNAME=$3
RACK_API_KEY=$4
RACK_REGION=$5

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
    curl \
    ssh \
    ;

# Download the rack client if it's not already.
if [ ! -f rack ]; then
    echo "Downloading the rack client..."
    # Linux 64-bit binary
    curl https://ec4a542dbf90c03b9f75-b342aba65414ad802720b41e8159cf45.ssl.cf5.rackcdn.com/1.2/Linux/amd64/rack > rack
    chmod +x rack
fi

# Configure rack client if it's not already
if [ $# -eq 6 ]; then
    echo "Configuring the rack client..."
    mkdir ~/.rack/
    echo "username = $RACK_USERNAME" > ~/.rack/config
    echo "api-key = $RACK_API_KEY" >> ~/.rack/config
    echo "region = $RACK_REGION" >> ~/.rack/config
elif [ ! -f ~/.rack/config ]; then
    echo "Configuring the rack client (interactive)..."
    ./rack configure
fi

# Select a review that was updated recently to find a relatively high review
# number.
# TODO: figure out a way to find the actual highest review number, without any
# trial & error.
ssh -p 29418 review.openstack.org gerrit query \
    --format JSON \
    is:open \
    limit:1 \
    > tmp

# Prune off the last line of the output.
sed -i '$ d' tmp

# Read the review number out of the JSON response.
MAX=`python -c "import json; print(json.loads(open('tmp', 'r').read())['number'])"`

# Iterate through all reviews, from 1 to our max.
for REVIEW_NUMBER in `seq 1 $MAX`
do
    # Get as much information about the review as we can.
    try ssh -p 29418 review.openstack.org gerrit query \
        --format JSON \
        --all-approvals \
        --all-reviewers \
        --comments \
        --current-patch-set \
        --dependencies \
        --files \
        --patch-sets \
        --submit-records \
        $REVIEW_NUMBER \
        limit:1 \
        > tmp

    # Prune off the last line of the output.
    sed -i '$ d' tmp

    # Upload to CDN.
    try rack files object upload \
        --container openstack-reviews \
        --content-type application/json \
        --name $REVIEW_NUMBER \
        --file tmp

    rm tmp;
done