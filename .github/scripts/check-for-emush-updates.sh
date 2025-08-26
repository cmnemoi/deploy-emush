#!/bin/bash

set -e
set -u

cd emush
git checkout develop
CURRENT=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/develop)
echo "Current commit: $CURRENT"
echo "Remote commit: $REMOTE"
if [ "$CURRENT" != "$REMOTE" ]; then
  echo "✅ Updates found - proceeding with deployment"
  echo "updated=true" >> $GITHUB_OUTPUT
else
  echo "❌ No updates found - skipping deployment"
  echo "updated=false" >> $GITHUB_OUTPUT
fi