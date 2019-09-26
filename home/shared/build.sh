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

LOCAL_USER=`whoami`
cd ~
LOCAL_HOME=`pwd`
cd - > /dev/null

if [ "${BRANCH}" = "None" ]; then
    BRANCH=master
fi

if [[ "$LAYERS"    = "None" ]] && \
   [[ "$OVERRIDES" = "None" ]] && \
   [[ "$ISSUE"     = "None" ]] && \
   ([[ "$DISTRO"   = "None" ]] || [[ "$DISTRO" = "openxt-main" ]]); then
    CUSTOM="regular"
#    NAME_SITE="oxt"
    echo "No override found, starting a regular build."
else
    CUSTOM="custom"
# TODO: stable-6 still has a site name, should we set it?
#    NAME_SITE="custom"
    echo "Override(s) found, starting a custom build."
fi

do_overrides () {
    for trip in $OVERRIDES; do
	name=$(echo $trip | cut -f 1 -d ':')
	git=$(echo $trip | cut -f 2 -d ':')
	branch=$(echo $trip | cut -f 3 -d ':')

	rm -rf /home/git/${LOCAL_USER}/$name.git
	git clone --bare git://$git/$name /home/git/${LOCAL_USER}/$name.git
	# The following code will name the override $BRANCH, to match what we're building
	if [[ $branch != "${BRANCH}" ]]; then
	    pushd /home/git/${LOCAL_USER}/$name.git
	    # Avoid being on a releavant branch by moving the HEAD to a tmp branch
	    git branch tmp
	    git symbolic-ref HEAD refs/heads/tmp
	    # Move $BRANCH to a backup location (avoid removing it, since some branches can't be removed)
	    #   Do not fail if the branch doesn't exist, it can happen
	    if git show-ref --quiet refs/heads/$BRANCH; then
	        git branch -m $BRANCH pleasedonthavethisalready$BRANCH
	    fi
	    # Create a branch named $BRANCH out of the $branch requested by the override
	    git branch $BRANCH $branch
	    # Make $BRANCH the head of the repository
	    git symbolic-ref HEAD refs/heads/$BRANCH
	    popd
	fi
    done
}

rm -rf /home/git/${LOCAL_USER}/*

echo "Cloning all repos..."
for repo in `/home/shared/list_repos.sh`; do
    git clone --quiet --bare https://github.com/OpenXT/${repo} /home/git/${LOCAL_USER}/${repo}.git
done

# Handle overrides
#   Note: It is against policy to set both $ISSUE and $OVERRIDES in the buildbot ui
if [[ $ISSUE != 'None' && $OVERRIDES != 'None' ]]; then
    echo "Cannot pass both a Jira ticket and custom repository overrides to build from."
    exit -1
elif [[ $ISSUE != 'None' && $OVERRIDES == 'None' ]]; then
    OVERRIDES=$( /home/shared/build_for_issue.sh $ISSUE )
else
    echo "Building using method other than Jira ticket."
fi
OFS=$IFS
IFS=','
[ "$OVERRIDES" != "None" ] && do_overrides
IFS=$OFS

rm -rf openxt
git clone -b ${BRANCH} file:///home/git/${LOCAL_USER}/openxt.git

cd openxt/build-scripts

# Modifying the build-scripts the way setup.sh would.
# Change the following if setup.sh changes
sed -i "s|\%CONTAINER_USER\%|build|" build.sh
sed -i "s|\%SUBNET_PREFIX\%|172.21|" build.sh
# No clean.sh in stable-6
if [[ $BRANCH != stable-6* ]]; then
    sed -i "s|\%CONTAINER_USER\%|build|" clean.sh
    sed -i "s|\%SUBNET_PREFIX\%|172.21|" clean.sh
fi
sed -i "s|\%GIT_ROOT_PATH\%|/home/git|" fetch.sh
cp ../version .

# Doing custom modifications to the scripts
# Hopefully we can keep it to a minimum
# 1. we just have one shared Windows VM, no per-user one
sed -i "s|^IP=.*$|IP=windows|" windows/build.sh
# 2. we're running in a subdir here, not in ~, tell everybody
sed -i "s|^ALL_BUILDS_SUBDIR_NAME=|ALL_BUILDS_SUBDIR_NAME=${LOCAL_HOME}/|" oe/build.sh
sed -i "s|^ALL_BUILDS_SUBDIR_NAME=|ALL_BUILDS_SUBDIR_NAME=${LOCAL_HOME}/|" debian/build.sh
sed -i "s|^ALL_BUILDS_SUBDIR_NAME=|ALL_BUILDS_SUBDIR_NAME=${LOCAL_HOME}/|" centos/build.sh
sed -i "s|^DEST=|DEST=${LOCAL_HOME}/|" windows/build.sh
# 3. stable-6 doesn't remove the dkms stuff properly in centos
#  TODO: fix
if [[ $BRANCH = stable-6* ]]; then
    sed -i -e '/sudo rm -rf \/usr\/src\/\${tool}-1.0/r /dev/stdin' centos/build.sh <<EOF
sudo rm -rf /var/lib/dkms/${tool}
EOF
fi
# 4. stable-6 doesn't handle build IDs?!
# 4bis. stable-6 doesn't build all steps by default...
# 4ter. fail on failure
#  TODO: fix
if [[ $BRANCH = stable-6* ]]; then
    sed -i -e "/.\/do_build.sh/r /dev/stdin" oe/build.sh <<'EOF'
# The return value of `do_build.sh` got hidden by `tee`. Bring it back.
ret=${PIPESTATUS[0]}
( exit $ret )

./do_build.sh -s xctools,ship,extra_pkgs,packages_tree | tee -a build.log
ret=${PIPESTATUS[0]}
( exit $ret )
EOF
    sed -i -e "s|^./do_build.sh|./do_build.sh -i ${BUILD_ID}|" oe/build.sh
fi
# 5. fix opkg config
#  TODO: replace the IP with a DNS name once we have one
if [[ $BRANCH = stable-6* ]]; then
    # Hack: there's only one EOF heredoc in oe/build.sh, which appends to .config
    sed -i "s|^EOF$|XENCLIENT_PACKAGE_FEED_URI=\"https://openxt.ainfosec.com/builds/${CUSTOM}/${BRANCH}/${BUILD_ID}/openxt-dev-${BUILD_ID}-${BRANCH}/packages/ipk\"\nEOF|" oe/build.sh
else
    sed -i "s|^XENCLIENT_PACKAGE_FEED_URI=.*$|XENCLIENT_PACKAGE_FEED_URI=\"https://openxt.ainfosec.com/builds/${CUSTOM}/${BRANCH}/${BUILD_ID}/packages/ipk\"|" oe/build.sh
fi
# 6. stable-6: Bring in Windows tools and fix .config
if [[ $BRANCH = stable-6* ]]; then
    sed -i -e "/^cd openxt$/r /dev/stdin" oe/build.sh <<'EOF'

mkdir wintools
rsync -r buildbot@172.21.152.1:/home/builds/win/$BRANCH/ wintools/
WINTOOLS="`pwd`/wintools"
WINTOOLS_ID="`grep -o '[0-9]*' wintools/BUILD_ID`"
EOF
    sed -i -e 's|^EOF$|WIN_BUILD_OUTPUT=\"$WINTOOLS\"\nXC_TOOLS_BUILD=$WINTOOLS_ID\nEOF|' oe/build.sh
fi
# 7. All: add the mirror as a pre-mirror
# TODO: add that to stable-6 too
if [[ $BRANCH = stable-6* ]]; then
    # Hack: there's only one EOF heredoc in oe/build.sh, which appends to .config
    sed -i "s|^EOF$|\nOE_TARBALL_MIRROR=\"https://openxt.ainfosec.com/mirror/\"\nEOF|" oe/build.sh
else
    # Hack: there's only one EOF heredoc in oe/build.sh, which appends to local.conf
    sed -i "s|^EOF$|\nPREMIRRORS_prepend = \"http://.*/.* https://openxt.ainfosec.com/mirror/ \\\n https://.*/.* https://openxt.ainfosec.com/mirror/ \\\n ftp://.*/.* https://openxt.ainfosec.com/mirror/\"\nEOF|" oe/build.sh
fi
# 8. Enable https certificates when supported
if grep validitems ../build/conf/local.conf-dist | grep -q web-certificates; then
    # Hack: there's only one EOF heredoc in oe/build.sh, which appends to local.conf
    sed -i 's|^EOF$|\nEXTRA_IMAGE_FEATURES += "web-certificates"\nEOF|' oe/build.sh
fi
# 9. rsync the tarball cache of regular master builds for custom master builds
if [[ $BRANCH = "master" ]]; then
    if [[ $CUSTOM = "regular" ]]; then
	# Update the local cache at the end of the build
	sed -i "/^exit$/i rsync -a --exclude='git*' downloads/ ~/downloads/" oe/build.sh
    else
	# Grab a copy of the cache at the beginning of a build
	# HACK: rely on the "# Build" comment
	sed -i "/^# Build$/i mkdir -p build/downloads ; rsync -a ~/downloads/ build/downloads/" oe/build.sh
    fi
fi

# OXT-993: we now use the build scripts from the git repo.
#   Since we want git_heads to be correct, we push our hack to a separate repo
#   that fetch.sh will rename once it's done creating git_heads.
#   The name can't end with .git or it will end up in git_heads.
rm -rf /home/git/${LOCAL_USER}/openxt.jed /home/git/${LOCAL_USER}/openxt.orig
cp -r /home/git/${LOCAL_USER}/openxt.git /home/git/${LOCAL_USER}/openxt.jed
git remote add jed file:///home/git/${LOCAL_USER}/openxt.jed
git -c user.name='Builder' -c user.email='nobody@openxt.ainfosec.com' commit --quiet -am 'Builder hacks'
git push --quiet jed ${BRANCH}
echo "mv /home/git/${LOCAL_USER}/openxt.git /home/git/${LOCAL_USER}/openxt.orig" >> fetch.sh
echo "mv /home/git/${LOCAL_USER}/openxt.jed /home/git/${LOCAL_USER}/openxt.git" >> fetch.sh

# Remove all builds in oe container before starting a new one
echo "Removing old build(s)..."
ssh oe "rm -rf [0-9]*"

# Build
echo "Starting the build"
if [[ $BRANCH = stable-6* ]]; then
    # stable-6 still uses do_build.sh and supports only one option (BUILD_ID)
    sed -i "s|^BRANCH=.*$|BRANCH=${BRANCH}|" build.sh
    ./build.sh ${BUILD_ID}
else
    ./build.sh -j 12 -i ${BUILD_ID} -b ${BRANCH}
fi

cd - > /dev/null

scp -r ~/xt-builds/${BUILD_ID} builds@openxt.ainfosec.com:/home/builds/${CUSTOM}/${BRANCH}/

exit
}
