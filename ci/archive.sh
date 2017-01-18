#!/bin/bash
set -e

SSH_PUBLIC_KEY=$1
SSH_PRIVATE_KEY_BODY=$2
SSH_USERNAME=$3
RACK_USERNAME=$4
RACK_API_KEY=$5
RACK_REGION=$6

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

# Collect the server's identity.
touch ~/.ssh/known_hosts
chmod 0600 ~/.ssh/known_hosts
ssh-keyscan -p 29418 review.openstack.org >> ~/.ssh/known_hosts

# Find a relatively high review number. This is not guaranteed to get us the
# most newest review, but it's likely that the most recent review will be
# included.
MAX=`ssh -p 29418 $SSH_USERNAME@review.openstack.org gerrit query limit:50 | grep number | sed -e 's/^  number: //' | sort | tail -1`

# Iterate through all reviews, from 1 to our max.
for REVIEW_NUMBER in `seq 1 $MAX`
do
    # Get as much information about the review as we can.
    for i in 1 2 3;
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
            $REVIEW_NUMBER \
            limit:1 \
            > tmp \
            && break || sleep 15
    done

    # Prune off the last line of the output.
    sed -i '$ d' tmp

    # Upload to CDN.
    for i in 1 2 3;
    do
        ./rack files object upload \
            --container openstack-reviews \
            --content-type application/json \
            --name $REVIEW_NUMBER \
            --file tmp \
            > /dev/null \
            && break || sleep 15
    done

    rm tmp;

    echo -ne "$REVIEW_NUMBER / $MAX\r"
done
