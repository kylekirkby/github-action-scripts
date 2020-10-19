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
    PR_NUMBER=$(jq ".pull_request.number" $GITHUB_EVENT_PATH)
    STATUSES_URL=$(jq ".pull_request.statuses_url" $GITHUB_EVENT_PATH)
}

function make_dirs(){
  if [ ! -d "$SITE_URL" ]; then
    echo "Making output directory \"$SITE_URL\""
    mkdir "$SITE_URL"
  fi
}

function setup_testing(){
  if [ "STATUSES_URL" != "" ]; then
    echo "Setting up for testing"
    # What is the URL going to be for this site?
    BUILDDIR="$AWS_STATIC_SITE_URL-$PR_NUMBER"
    URL="http://$BUILDDIR.websitepreview.linaro.org"
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
    elif [ -d "$SITE_URL" ]; then
      echo "Copying $SITE_URL to $BUILDDIR"
      cp -r "$SITE_URL" "$BUILDDIR"
    fi
    # Override the environment variables so that Jekyll builds
    # the site the way we want it built and where we want it built.
    export JEKYLL_ENV="testing"
    export SITE_URL="$BUILDDIR"
  fi
}

function post_build_cleanup(){
  if [ "$STATUSES_URL" != "" ]; then
    echo "Post-build cleanup"
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
  if [ "$STATUSES_URL" != "" ]; then
    echo "post_build_deploy_preview"
    sudo chown -R www-data "$BUILDDIR"
    chmod -R g+w "$BUILDDIR"
    # Move the built directory into the preview space
    mv "$BUILDDIR" /srv/websitepreview/
    # Send the status update to GitHub for the preview URL
    DATA="{\"state\": \"success\", \"target_url\": \"$URL\", \"context\": \"Deploy preview\", \"description\": \"Deployment complete\"}"
    curl -s -H "Content-Type: application/json" -H "Authorization: token $GITHUB_TOKEN" -d "$DATA" "$STATUSES_URL"
  fi
}

function post_build_failed_preview(){
  if [ "$STATUSES_URL" != "" ]; then
    echo "post_build_failed_preview"
    # Send the status update to GitHub to say it failed
    DATA="{\"state\": \"failure\", \"context\": \"Deploy preview\", \"description\": \"Deployment failed\"}"
    curl -s -H "Content-Type: application/json" -H "Authorization: token $GITHUB_TOKEN" -d "$DATA" "$STATUSES_URL"
  fi
}

function docker_build_site() {
  echo "Building the site ..."
  echo "docker run -e JEKYLL_ENV=$JEKYLL_ENV -u $(id -u):$(id -g) -v $GITHUB_WORKSPACE:/srv/source linaroits/jekyllsitebuild:latest build-site.sh"
  docker run --rm \
    -t \
    --cap-drop ALL \
    -e JEKYLL_ENV="$JEKYLL_ENV" \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -u "$(id -u)":"$(id -g)" \
    -v "$GITHUB_WORKSPACE":/srv/source \
    linaroits/jekyllsitebuild:latest build-site.sh
}

cd "$GITHUB_WORKSPACE" || exit 1
setup_vars
setup_testing
make_dirs || exit 1
# Use PIPESTATUS to check the exit code from docker_build_site and
# not the (successful) output from tee.
docker_build_site 2>&1 | tee "$GITHUB_WORKSPACE/../jekyll-output" ; pipe_status=${PIPESTATUS[0]}
if [ $pipe_status != 0 ]
then
  # Failure
  post_build_cleanup
  post_build_failed_preview
  touch "$GITHUB_WORKSPACE/../jekyll-fail"
  exit 1
else
  # Success
  post_build_cleanup
  post_build_deploy_preview
  touch "$GITHUB_WORKSPACE/../jekyll-success"
  # Drop out of the script with the status returned by "touch"
fi
