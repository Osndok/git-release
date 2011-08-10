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
SCRIPT_VERSION="1.0.0"
# For updates or examples please visit: http://www.osndok.com/git-release/
#
# CHANGELOG:
#   1.0   - always support *BOTH* the branch and the tag options
#          \- no-push option for testing changes before commitment
#          \- machine-readable script version
#          \- hooks for pre & post versioning
#          \- one-push per ref (to aid in server-side processing)
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
DO_PUSH="true"

# on master branch, or wanting to further-refine... must make a remote branch
if echo $REMOTE_BRANCH | grep master ; then
  echo 1>&2 "WARNING: mainline detected, you probably want a release-branch"
  DO_BRANCH=true
fi

[ "$1" == "--branch" ] && DO_BRANCH=true
[ "$1" == "--tag" ] && DO_BRANCH=""
[ "$1" == "--no-push" ] && DO_PUSH=""
[ "$2" == "--no-push" ] && DO_PUSH=""

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

  # @bug: need to check for non-version/uncommited changes (there are 'reset --hard' steps in recovery)

  set -x

# (0) - run any pre-version hook we might find
	[ -x ".version.pre-branch" ]   && . ./.version.pre-branch
	[ -x "version/pre-branch.sh" ] && . ./version/pre-branch.sh

# (0.5) check to see if our target branch is already created (someone else released this version)
	if git branch -r | grep $NEW_BRANCH_NAME ; then
		# TODO: might be nice to setup the remote version branches in the local repo.
		fatal "branch named '$NEW_BRANCH_NAME' already in remote repo?!"
	fi

# (1) - make a local branch to remember where the branches are forking (will balk at a failed/aborted release-attempt)
  git branch release-attempt

# (2) - make a version-number-advancing-commit on the mainline (will automatically balk at two competing releases)
  echo $NEXT_VERSION > $version_file
  git add $version_file
  git commit -m "$NEW_BRANCH_NAME branched off" $version_file

# (3) - make the new remote branch, starting from where we *WERE*
  # without pushing the new branch to the server (yet), make it start out where we left off
  # by manually setting it up to track the remote (but as-of-yet non-existant) branch at
  # the former location (release-attempt: temp. branch created earlier).
	git checkout -b $NEW_BRANCH_NAME release-attempt
	git config --add "branch.$NEW_BRANCH_NAME.remote" "$REMOTE"
	git config --add "branch.$NEW_BRANCH_NAME.merge"  "refs/heads/$NEW_BRANCH_NAME"

# (3.5) - run any new-branched hook we might find
	[ -x ".version.new-branch" ]   && . ./.version.pre-branch
	[ -x "version/new-branch.sh" ] && . ./version/pre-branch.sh

# (4) - commit to this new branch a new version file indicating a pre-release (ends in a period)
  echo ${VERSION}. > "$version_file"
  git add $version_file
  git commit -m "v: pre-${release_prefix}${VERSION}.0" $version_file

# (5) - push the new branch to the server, along with the just-branched commit
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $NEW_BRANCH_NAME > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "branch creation deferred, continuing"
	else
	  echo "ERROR: branch creation request failed" 1>&2
	  # Our first step (branch creation) failed. So to recover, reset the current branch to 'release-attempt' (and delete the same)
	  git reset --hard release-attempt
	  git branch -D release-attempt
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi

# (6) - now we have a reasonable degree of certainity that the branch was accepted, push the mainline commit
#       we made earlier at step (2), which advances the version number on the "mainline" (or sub-branch)
	if [ -n "$DO_PUSH" ] && ! git push $REMOTE $BRANCH:$MERGE > $TEMP 2>&1 ; then
		if egrep -i '(later|defer)' $TEMP ; then
			echo "mainline commit deferred, continuing"
		else
			echo "ERROR: branch creation succeeded, but mainline commit failed" 1>&2
			# To recover, swap the placement of $BRANCH & release-attempt to be more logical
			NEW_HASH=$(git rev-parse HEAD)
			git reset --hard release-attempt
			git checkout release-attempt
			git reset --hard $NEW_HASH
			# NB: 'release-attempt' will still be present (and block an immediate retry of the release)
			echo "NB: the conflicting commits are on the (now-active) 'release-attempt' branch."
			echo "    these commit(s) should *probably* be merged with the new remote master branch."
			tail  $TEMP
			rm -f $TEMP
			exit 1
		fi
	fi

# (7) - delete the release-attempt branch, as we have successfully made a release branch
  git branch -d release-attempt

# (8) - run any post-version hook we might find
	[ -x ".version.post-branch" ]   && . ./.version.post-branch
	[ -x "version/post-branch.sh" ] && . ./version/post-branch.sh

  date
  echo "Success, NOW ON BRANCH $NEW_BRANCH_NAME."
  echo " * release again to tag a specific version on this branch"
  echo " * switch back to the former branch with 'git checkout $BRANCH'"
  rm -f $TEMP
  exit 0
else
  # we are NOT making a release-branch, but a release-commit... for this we advance the version_file by one and place/push a tag
  # first, some minor branch-name enforcement. Make sure the current branch-name jives with the version number...

  #easy... what follows the string "version-"; modify if not using version-* pattern (e.g. "v*" @ kernel.org)
  BRANCH_VERSION=`echo $REMOTE_BRANCH | cut -f2 -d-`

# (0) - run any pre-version hook we might find
	[ -x ".version.pre-tag" ]   && . ./.version.pre-tag
	[ -x "version/pre-tag.sh" ] && . ./version/pre-tag.sh

  echo $NEXT_VERSION > "$version_file"
  NAME=${release_prefix}${NEXT_VERSION}

	OLD_HASH=$(git rev-parse HEAD)

  #NB: this commit is for the version file (other work-area/unmerged/unsaved changes are ignored)
  git commit -m "$NAME" "$version_file"
  git tag -m "$NAME" "$NAME"
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $BRANCH > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "$BRANCH commit deferred, continuing"
	else
	  echo "$BRANCH commit was rejected, this probably means that your repo is not up-to-date with the server." 1>&2
	  # 'rollback' the version comming & revert the .version file
	  # *hopefully* this will not interfere with any dirty files
	  git reset $OLD_HASH
	  git checkout "$version_file"
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi

	# Now that we are reasonably sure that the in-branch commit was recorded, we'll push the same hash to the tag.
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $NAME > $TEMP 2>&1 ; then
	if egrep -i '(later|defer)' $TEMP ; then
	  echo "tag commit defered, continuing"
	  #we will re-fetch the tag from the server later... if it is accepted
	  git tag -d "$NAME"
	else
		git fetch
		echo "ERROR: server accepted branch-advancement, but rejected tag placement" 1>&2
		echo "       there will likely be conflicting $NAME tags.";
	  tail  $TEMP
	  rm -f $TEMP
	  exit 1
	fi
  fi

# (3) - run any post-version hook we might find
	[ -x ".version.post-tag" ]   && . ./.version.post-tag
	[ -x "version/post-tag.sh" ] && . ./version/post-tag.sh

  echo "Success, version $NEXT_VERSION tagged"
  rm -f $TEMP
  exit 0
fi
