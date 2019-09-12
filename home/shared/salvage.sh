#!/bin/bash

{
# Making the whole script one big block.
# That way, supposedly, it's entirely loaded in RAM at call time.
# So now modifying the script while it's in use shouldn't break anything

BUILD_ID=$1
BRANCH=$2
LAYERS=$3
OVERRIDES=$4
ISSUE=$5
DISTRO=$6

umask 0022

if [ "${BRANCH}" = "None" ]; then
    BRANCH=master
fi

if [[ "$LAYERS"    = "None" ]] && \
   [[ "$OVERRIDES" = "None" ]] && \
   [[ "$ISSUE"     = "None" ]] && \
   ([[ "$DISTRO"   = "None" ]] || [[ "$DISTRO" = "openxt-main" ]]); then
    CUSTOM="regular"
    echo "No override found, starting a regular build."
else
    CUSTOM="custom"
    echo "Override(s) found, starting a custom build."
fi

cd openxt/build-scripts

>fetch.sh
./build.sh -i ${BUILD_ID} -b ${BRANCH} -O -C -D -W

cd - > /dev/null

scp -r ~/xt-builds/${BUILD_ID} builds@openxt.ainfosec.com:/home/builds/${CUSTOM}/${BRANCH}/

exit
}
