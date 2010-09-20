#!/bin/bash
#
# Copyright 2009, Robert Hailey <git@osndok.com>
#
# This script is an "easy" self-contained tagging & branching release
# system for git repositories that follow the mainline-versioning
# method described in the following Perforce white paper:
#
# --> http://www.perforce.com/perforce/papers/bestpractices.html <--
#
# Specifically, it grants any user with the ability to perform a
# "git-push" to the blessed "release server" the ability to make a
# new release (by either a branch or tag). Many advanced git users
# may find this script totally unnecessary.
#
# The version of this script is "0.9-autoport"
# For updates or examples please visit: http://www.osndok.com/git-release/
#
# CHANGELOG:
#   0.10  - always support *BOTH* the branch and the tag options
#   0.9   - add these change log entries, dont require branch naming convention
#   0.8   - fix version-branching when deferred branch updates are enabled
#   0.7   - support deferred branch updates by ignoring certain "failures"
#   0.6   - fix incorrect branch name on push
#
# BUGS:
#   May fail or produce undesirable results if run to branch from a
#      commit point which is not a head.
#   May give unintuitive errors for failure conditions.
#   Might destroy all your data and eat your children.
#
# LIMITATIONS:
#   To minimize user-errors, will only operate on branches which are
#     tracking remote branches on the blessed release_machine
#     (as defined in this file)
#
# USAGE:
#   Generally, one only needs to run this script with no arguments.
#   Depending on which remote branch (or mainline) the current HEAD
#   follows, this script will automatically increment the version
#   numbers and create the necessary tags and branches.
#
#   While not recommended, minor-branches are partially implemented,
#   and might be created if you are having a good day and call the
#   script with the "--branch' argument. Presently buggy, this will
#   likely only work on the head of the version branch.
#     eg-$> ./release.sh --branch
#
#   When used consistently, one may determine what the "version" of
#   a source tree is by simply examining the version-file; by default
#   this is named ".version".  If this is a whole number, it is from
#   the mainline development branch, if it ends in a period, it is a
#   pre-release (from a version-branch).
#
#   The version file is kept "at-or-above" the release and is tracked
#   using git. A side effect of this is making it harder to merge
#   version-branches (as at least the version files will conflict at
#   the first commit); this is seen as a good thing, as it may indicate
#   when merging branches which don't belong together. A natural
#   consequence of the enumeration is that the head of the mainline
#   will always have the version number of the "NEXT MAJOR RELEASE";
#
#   e.g. if a release "3.1.4" was the last release, the mainline will
#     show "4" as it's version number, and the version-3 branch will
#     show at least "3.2" and the version-3.1 branch will show "3.1.5".
#
# DISCLAIMER:
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# ADDITIONALLY:
#
#   Long live git!
#
head=.git/HEAD
release_machine=release.osndok.com
version_file=.version

#changing these likely will neccesitate changing some of the re-parsing code below
release_prefix=v
branch_prefix="version-"

function fatal() {
  echo 1>&2 "FATAL: $*"
  exit 1
}

#hereafter, stop on first error
set -e

grep -q refs/heads/ $head || fatal "not in a local branch?"

BRANCH=`cat $head | cut -f3- -d/`
echo "BRANCH=$BRANCH"

REMOTE=`git config --get branch.$BRANCH.remote` || fatal "not on a remote-tracking branch"
MERGE=`git config --get branch.$BRANCH.merge`
REMOTE_URL=`git config --get remote.$REMOTE.url`

[ -z "$REMOTE" ] && fatal "not on a remote-tracking branch."

echo "REMOTE=$REMOTE"
echo "MERGE=$MERGE"
echo "REMOTE_URL=$REMOTE_URL"

echo $REMOTE_URL | grep -q $release_machine || fatal "$BRANCH does not track to $release_machine"

#mainline will look like: MERGE=refs/heads/master
#version branch like:     MERGE=refs/heads/version-3

#branch_prefix change will require this to change
REMOTE_BRANCH=`echo $MERGE | cut -f3- -d/`

DO_BRANCH=""

# on master branch, or wanting to further-refine... must make a remote branch
if echo $REMOTE_BRANCH | grep master ; then
  echo 1>&2 "WARNING: mainline detected, you probably want a release-branch"
  DO_BRANCH=true
fi

[ "$1" == "--branch" ] && DO_BRANCH=true
[ "$1" == "--tag" ] && DO_BRANCH=""

# if no version file exists, make one that contains "1"
[ -e "$version_file" ] || echo 1 > $version_file
VERSION=`cat "$version_file"`

#iff there is no period in the present version number, treat it as a mainline (MAJOR) number (1,2,3,4)
if echo $VERSION | grep -q '\.' ; then
  #treat it as a sub-version (e.g. 3.1.2)
  #just increment the last decimal value... whatever that is.
  SMALLEST=`echo $VERSION | rev | cut -f1 -d. | rev`
  PREFIX=`echo $VERSION | rev | cut -f2- -d. | rev`

  #if it ends in a period, increment that trailing period into a zero (so I guess "2." -> "2.-1"?) ha ha...
  if [ -z "$SMALLEST" ]; then
    SMALLEST=0
  else
    let SMALLEST=$SMALLEST+1
  fi
  NEXT_VERSION=${PREFIX}.${SMALLEST}
else
  #no period... just increment the whole number
  let NEXT_VERSION=${VERSION}+1
fi

echo "Branch: $BRANCH"
echo "From version : $VERSION"
echo "To   version : $NEXT_VERSION"

git fetch

TEMP=`mktemp /tmp/git-release.XXXXXXXX`

if [ "$DO_BRANCH" == "true" ]; then
  echo "New branch at: ${VERSION}. -> ${VERSION}.0 (after release on that branch)"

  # if we are trying to branch BEFORE the first release, they are not following the release method;
  # this would surely generate confusion
  grep '\.$' $version_file && fatal "do not branch from a release branch before first release commit (commit ${VERSION}0 first!)"

  #new branch name is easy, it's whatever the pre-branch version was
  NEW_BRANCH_NAME=${branch_prefix}${VERSION}

  set -x

# (1) - make a local branch to remember where the branches are forking (will balk at a failed/aborted release-attempt)
  git branch release-attempt

# (2) - make a version-number-advancing-commit on the mainline (will automatically balk at two competing releases)
  echo $NEXT_VERSION > $version_file
  git add $version_file
  git commit -m "$NEW_BRANCH_NAME branched off" $version_file
  #must push current branch to detect potential conflict; TODO: maybe support ex-post-facto branching from release-tag points?
  if ! git push $REMOTE $BRANCH:$MERGE > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "commit defered, continuing"
	else
	  echo "commit rejected"
	  tail  $TEMP
	  rm -f $TEMP
	  exit 1
	fi
  fi

# (3) - make the new remote branch, starting from where we *WERE*
  #bug?: being paranoid about potentially being confused and overwriting a pre-existing remote branch name, let's check first...
  git branch -r | grep $NEW_BRANCH_NAME && fatal "branch named '$NEW_BRANCH_NAME' already in remote repo?!"

  #start it out where we left off (the branch point)
  if ! git push $REMOTE release-attempt:refs/heads/$NEW_BRANCH_NAME > $TEMP 2>&1 ; then
    if egrep -i '(later|defer)' $TEMP ; then
	  echo "commit defered, continuing"
	else
	  echo "commit rejected"
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
	# we cannot use the remote branch, as it is undergoing testing; will be independant for the moment
	git checkout -b $NEW_BRANCH_NAME release-attempt
	echo "WARN: work-around setup for $NEW_BRANCH_NAME remote-tracking (not yet accepted on server)!"
	git config --add "branch.$NEW_BRANCH_NAME.remote" "$REMOTE"
	git config --add "branch.$NEW_BRANCH_NAME.merge"  "refs/heads/$NEW_BRANCH_NAME"
  else
  
  #make a local branch of the same name which tracks this newly-created remote branch
  #simultaneously switches to that new branch (NB: might still be merging uncommitted changes)
  git checkout --track  -b $NEW_BRANCH_NAME $REMOTE/$NEW_BRANCH_NAME
  
  fi

# (4) - commit to this new branch a new version file indicating a pre-release (ends in a period)
  echo ${VERSION}. > "$version_file"
  #push this commit to...
  git add $version_file
  git commit -m "v: pre-${release_prefix}${VERSION}.0" $version_file
  if ! git push $REMOTE $NEW_BRANCH_NAME > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "commit defered, continuing"
	else
	  echo "commit rejected"
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi

# (5) - delete the release-attempt branch, as we have successfully made a release branch
  git branch -d release-attempt

  date
  echo "Success, NOW ON BRANCH $NEW_BRANCH_NAME"
  rm -f $TEMP
  exit 0
else
  # we are NOT making a release-branch, but a release-commit... for this we advance the version_file by one and place/push a tag
  # first, some minor branch-name enforcement. Make sure the current branch-name jives with the version number...

  #easy... what follows the string "version-"; modify if not using version-* pattern (e.g. "v*" @ kernel.org)
  BRANCH_VERSION=`echo $REMOTE_BRANCH | cut -f2 -d-`

  echo $NEXT_VERSION > "$version_file"
  NAME=${release_prefix}${NEXT_VERSION}

  #NB: this commit is for the version file (other work-area/unmerged/unsaved changes are ignored)
  git commit -m "$NAME" "$version_file"
  git tag -m "$NAME" "$NAME"
  if ! git push $REMOTE $BRANCH > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "commit defered, continuing"
	else
	  echo "commit rejected"
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi
  if ! git push $REMOTE $NAME > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "tag commit defered, continuing"
	  #we will re-fetch the tag from the server later... if it is accepted
	  git tag -d "$NAME"
	else
	  echo "tag commit rejected"
	  tail  $TEMP
	  rm -f $TEMP
	  exit 1
	fi
  fi

  echo "Success, version $NEXT_VERSION tagged"
  rm -f $TEMP
  exit 0
fi
