#!/bin/bash
# shellcheck disable=SC2154
#
# Note: do NOT use "set -e" in this script because we need the "if" statement to execute and it won't
# if we use "set -e"

function setup_vars(){
    # The following vars are set from .github-env
    # AWS_STATIC_SITE_URL
    # JEKYLL_ENV
    # SITE_URL
    PR_NUMBER=$(jq -r ".pull_request.number" $GITHUB_EVENT_PATH)
    STATUSES_URL=$(jq -r ".pull_request.statuses_url // empty" $GITHUB_EVENT_PATH)
}

function make_dirs(){
  if [ ! -d "$SITE_URL" ]; then
    echo "Making output directory \"$SITE_URL\""
    mkdir "$SITE_URL"
  fi
}

check_multi_repo() {
  # A multi-repo site is defined by the presence of manifest.json.
  #
  # If that file exists, we look for the tags in the file, which
  # specifies the env var names that must be used to tell this
  # script where a local copy of that repo can be found.
  #
  # We then build up a list of mounts for Docker so that it can
  # access those repo copies.
  #
  # Use -g to make this a global variable (i.e. it lasts after
  # the function finishes).
  declare -a -g DOCKER_MOUNTS
  DOCKER_MOUNTS=()
  if [ ! -f "manifest.json" ]; then
    echo "No multi-repo configuration to manage."
    return
  fi
  #
  # Get the tags from the file.
  declare -a tags
  tags=($(grep \"tag\" manifest.json | cut -d':' -f2))
  tag_count="${#tags[@]}"
  if [ "$tag_count" == 0 ]; then
    echo "Cannot find repo tags in manifest file."
    exit 1
  fi
  #
  # Do any of them exist as variables that point to directories?
  for ((i=0; i < tag_count; i++))
  do
    # Need to strip extraneous chars off the tag string
    tag="${tags[$i]}"
    # Strip the leading " and the trailing ",
    tag="${tag:1:-2}"
    # Does that tag name exist as a variable and have a value?
    tag_val="${!tag}"
    if [ "$tag_val" != "" ]; then
      # Does the value point to a directory?
      if [ -d "$tag_val" ]; then
        # Construct a Docker mount command
        DOCKER_MOUNTS+=(-v $tag_val:/srv/$tag)
      else
        echo "$tag points to $tag_val but that doesn't seem to be a directory"
      fi
    else
      echo "$tag doesn't appear to have a value"
    fi
  done
}

function setup_testing(){
  if [ ! -z "$STATUSES_URL" ]; then
    echo "Setting up for testing"
    # What is the URL going to be for this site?
    BUILDDIR="$AWS_STATIC_SITE_URL-$PR_NUMBER"
    URL="http://$BUILDDIR.ghactions.linaro.org"
    cat > _config-testing.yml << EOF
url: "$URL"
destination: "$BUILDDIR"
production: false
future: true
EOF
    # In order to avoid rebuilding images unnecessarily, copy
    # an existing version of the site.
    #
    # Start by making sure we don't have an existing build.
    rm -rf "$BUILDDIR"
    #
    if [ -d "/srv/websitepreview/$BUILDDIR" ]; then
      echo "Copying previous website preview into current directory"
      cp -r "/srv/websitepreview/$BUILDDIR" .
    elif [ -d "/srv/site-builds/$SITE_URL" ]; then
      echo "Copying $SITE_URL to $BUILDDIR"
      cp -r "/srv/site-builds/$SITE_URL" "$BUILDDIR"
    fi
    # Override the environment variables so that Jekyll builds
    # the site the way we want it built and where we want it built.
    export JEKYLL_ENV="testing"
    export SITE_URL="$BUILDDIR"
  fi
}

function post_build_cleanup(){
  if [ ! -z "$STATUSES_URL" ]; then
    echo "post_build_cleanup"
    # Remove the temporary config file otherwise git will be a bit unhappy
    rm _config-testing.yml
    # If we already have a preview directory with this name, we need to remove
    # it first.
    if [ -d "/srv/websitepreview/$BUILDDIR" ]; then
      rm -r /srv/websitepreview/"$BUILDDIR"
    fi
  fi
}

function post_build_deploy_preview(){
  if [ ! -z "$STATUSES_URL" ]; then
    echo "post_build_deploy_preview"
    # Change group so that www-data can read the site for previews. We do this
    # rather than owner so that the owner (ubuntu) continues to have rw perms
    # which is important when cleaning up.
    sudo chgrp -R www-data "$BUILDDIR"
    # Move the built directory into the preview space
    mv "$BUILDDIR" /srv/websitepreview/
    # Send the status update to GitHub for the preview URL
    DATA="{\"state\": \"success\", \"target_url\": \"$URL\", \"context\": \"Deploy preview\", \"description\": \"Deployment complete\"}"
    curl -s -S -H "Content-Type: application/json" -H "Authorization: token $TOKEN" -d "$DATA" "$STATUSES_URL" >/dev/null
  fi
}

function post_build_failed_preview(){
  if [ ! -z "$STATUSES_URL" ]; then
    echo "post_build_failed_preview"
    # Send the status update to GitHub to say it failed
    DATA="{\"state\": \"failure\", \"context\": \"Deploy preview\", \"description\": \"Deployment failed\"}"
    curl -s -S -H "Content-Type: application/json" -H "Authorization: token $TOKEN" -d "$DATA" "$STATUSES_URL" >/dev/null
  fi
}

function docker_build_site() {
  echo "Building the site ..."
  echo "docker run -e JEKYLL_ENV=$JEKYLL_ENV ${DOCKER_MOUNTS[@]} -u $(id -u):$(id -g) -v $GITHUB_WORKSPACE/website:/srv/source linaroits/jekyllsitebuild:latest"
  docker run --rm \
    -t \
    --cap-drop ALL \
    -e JEKYLL_ENV="$JEKYLL_ENV" \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    "${DOCKER_MOUNTS[@]}" \
    -u "$(id -u)":"$(id -g)" \
    -v "$GITHUB_WORKSPACE/website":/srv/source \
    linaroits/jekyllsitebuild:latest
}

cd "$GITHUB_WORKSPACE/website" || exit 1
setup_vars
setup_testing
make_dirs || exit 1
check_multi_repo
docker_build_site
result=$?
post_build_cleanup
if [ $result -ne 0 ]; then
  post_build_failed_preview
else
  post_build_deploy_preview
fi
exit $result
