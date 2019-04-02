#!/bin/bash

set -ex

source common.sh

# Get the various images
source get_images.sh

# Either pull or build the ironic images
# To build the IRONIC image set
# IRONIC_IMAGE=https://github.com/metalkube/metalkube-ironic
for IMAGE_VAR in IRONIC_IMAGE IRONIC_INSPECTOR_IMAGE ; do
    IMAGE=${!IMAGE_VAR}
    # Is it a git repo?
    if [[ "$IMAGE" =~ "://" ]] ; then
        REPOPATH=~/${IMAGE##*/}
        # Clone to ~ if not there already
        [ -e "$REPOPATH" ] || git clone $IMAGE $REPOPATH
        cd $REPOPATH
        export $IMAGE_VAR=localhost/${IMAGE##*/}:latest
        sudo podman build -t ${!IMAGE_VAR} .
        cd -
    else
        sudo podman pull "$IMAGE"
    fi
done

pushd $IRONIC_DATA_DIR/html/images

if [ ! -e "$RHCOS_IMAGE_FILENAME_OPENSTACK.md5sum" -o \
     "$RHCOS_IMAGE_FILENAME_OPENSTACK" -nt "$RHCOS_IMAGE_FILENAME_OPENSTACK.md5sum" ] ; then
    md5sum "$RHCOS_IMAGE_FILENAME_OPENSTACK" | cut -f 1 -d " " > "$RHCOS_IMAGE_FILENAME_OPENSTACK.md5sum"
fi

ln -sf "$RHCOS_IMAGE_FILENAME_OPENSTACK" "$RHCOS_IMAGE_FILENAME_LATEST"
ln -sf "$RHCOS_IMAGE_FILENAME_OPENSTACK.md5sum" "$RHCOS_IMAGE_FILENAME_LATEST.md5sum"
popd

for name in ironic ironic-inspector dnsmasq httpd; do 
    sudo podman ps | grep -w "$name$" && sudo podman kill $name
    sudo podman ps --all | grep -w "$name$" && sudo podman rm $name -f
done

# Remove existing pod
if  sudo podman pod exists ironic-pod ; then 
    sudo podman pod rm ironic-pod -f
fi

# Create pod
sudo podman pod create -n ironic-pod 

# Start dnsmasq, http, and dnsmasq containers using same image
sudo podman run -d --net host --privileged --name dnsmasq  --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared --entrypoint /bin/rundnsmasq ${IRONIC_IMAGE} 

sudo podman run -d --net host --privileged --name httpd --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared --entrypoint /bin/runhttpd ${IRONIC_IMAGE} 

sudo podman run -d --net host --privileged --name ironic --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared ${IRONIC_IMAGE} 

# Start Ironic Inspector 
sudo podman run -d --net host --privileged --name ironic-inspector --pod ironic-pod "${IRONIC_INSPECTOR_IMAGE}"
