#!/bin/bash
#
# Copyright 2015, Robert Hailey <git@osndok.com>
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
SCRIPT_VERSION="1.3.7"
# For updates or examples please visit:
#   https://github.com/Osndok/git-release
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
release_machine=
version_file=.version
version_args=.version_args
build_file=.build_number

# If 'true', then running ./release.sh on the master branch will generate a *tag* (not a branch)
TAG_MAINLINE=true

# If 'true', then the "features window" branching pattern will be used (branch and increment)
# If 'false' then the "features welcome" pattern is used (branch, truncate, and increment)
#
# This can be overridden at runtime (for extra confusion, or experimentation):
# --branch  is the conventional branch command, where the branch receives sub-divided enumerations
#           (master:1.2 -> branch:1.2.0, 1.2.1, 1.2.2 & master:1.3, 1.4, 1.5)
# --branch2 is an alternative branch command, wherein the branch maintains the monotonic incrementation 
#           formerly on the mainline (master:1.2.3 -> branch:1.2.4 & master: 1.3.0, 1.3.1, ...)
#
DO_BRANCH2=true

#changing these likely will neccesitate changing some of the re-parsing code below
release_prefix=v
branch_prefix="version-"
build_tag_prefix="refs/tags/build/"

function fatal() {
  echo 1>&2 "FATAL: $*"
  exit 1
}

head=.git/HEAD

#hereafter, stop on first error
set -e

# Make sure we are at the project root... where this file should be...
cd $(dirname $0)

if [ -e .git ]; then
	grep -q refs/heads/ $head || fatal "not in a local branch?"
elif [ "$#" -eq "1" ] && [ "$1" == "--build-needed" ]; then
	# The only supported operation without a git directory is '--build-needed', which always returns true (because we can't tell).
	echo 2>&1 "warning: no .git directory, so --build-needed is always true"
	echo "TRUE"
	exit 0
else
	echo 2>&1 "fatal: no .git directory"
fi

BRANCH=$( cat $head | cut -f3- -d/ )
#echo "BRANCH=$BRANCH"   # e.g. master, version-2, version-2.1, version-2.1.3

#
# "--bless" adds entries like this into your config:
#
#[branch "master"]
#        remote = origin
#        merge = refs/heads/master
#        rebase = true
#
# b/c these were formerly required of git, but no longer strictly needed,
# and we require them for sanity checking.
#
if [ "$#" -eq "1" ] && [ "$1" == "--bless" ]; then
	git config branch.$BRANCH.remote origin
	git config branch.$BRANCH.merge  refs/heads/$BRANCH
	git config branch.$BRANCH.rebase true
	exit 0
fi

REMOTE=$(git config --get branch.$BRANCH.remote)  || fatal "please set 'branch.$BRANCH.remote', or run '--bless' to guard against accidentally pushing the wrong branches"
MERGE=$(git config --get branch.$BRANCH.merge)    || fatal "branch.$BRANCH.merge config item is not set"
REMOTE_URL=$(git config --get remote.$REMOTE.url) || fatal "remote.$REMOTE.url config item is not set"

[ -z "$REMOTE" ] && fatal "not on a remote-tracking branch. 2"
[ -z "$MERGE"  ] && fatal "unable to determine remote branch name"

#echo "REMOTE=$REMOTE"         # e.g. 'origin'
#echo "MERGE=$MERGE"           # or the remote side, 'refs/heads/master', 'refs/heads/version-2', 'refs/heads/version/2.1'
#echo "REMOTE_URL=$REMOTE_URL" # the remote machine name

if [ -n "$release_machine" ]; then
	echo $REMOTE_URL | grep -q $release_machine || fatal "$BRANCH does not track to $release_machine"
fi

#mainline will look like: MERGE=refs/heads/master
#version branch like:     MERGE=refs/heads/version-3

#branch_prefix change will require this to change
REMOTE_BRANCH=$(echo $MERGE | cut -f3- -d/)

LAST_BUILD=0
if [ -e $build_file ]; then
	if read LAST_BUILD < $build_file ; then
		AND_BUILD_FILE=$build_file
	else
		echo 1>&2 "$build_file: unreadable (make sure it contains an end-of-line marker)"
		exit 1
	fi
else
	AND_BUILD_FILE=""
fi
let NEXT_BUILD=1+$LAST_BUILD

ARGS=""
BUILD_ONLY=""
DO_BRANCH="default"
DO_PUSH="true"

for arg in "$@"
do
	case "$arg" in
"--push")       DO_PUSH="true"
    ;;
"--no-push")    DO_PUSH=""
    ;;
# --branch2 is an alternative branch command, wherein the branch maintains the monotonic incrementation 
#           formerly on the mainline (master:1.2.3 -> branch:1.2.4 & master: 1.3.0, 1.3.1, ...)
"--branch2")    DO_BRANCH2="true"
                DO_BRANCH="true"
	;;
# --branch  is the conventional branch command, where the branch receives sub-divided enumerations
#           (master:1.2 -> branch:1.2.0, 1.2.1, 1.2.2 & master:1.3, 1.4, 1.5)
"--branch1")    DO_BRANCH2="false"
                DO_BRANCH="true"
	;;
"--branch")     DO_BRANCH="true"
    ;;

"--tag")        DO_BRANCH=""
    ;;
"--build2")
	echo 1>&2 "Did you mean, '--branch2' ???"
	exit 1
	;;
"--build-only")
	[ -e $build_file ] || fatal "this project does not seem to require or support monotonic build numbers"
	BUILD_ONLY="true"
    ;;
"--build-needed")
	if git show --name-only HEAD | egrep -q "^($build_file|$version_file)" ; then
		echo "FALSE"
		exit 1
	else
		echo "TRUE"
		exit 0
	fi
	;;
*) ARGS="$ARGS $arg"
   ;;
	esac
done

if [ -n "$ARGS" ]; then
	echo "$ARGS" > $version_args
	git add $version_args
	AND_ARGS_FILE=$version_args
	MESSAGE_EXTRA=" $ARGS"
elif [ -e $version_args ]; then
	git rm -f $version_args || rm -fv $version_args
	AND_ARGS_FILE=$version_args
	MESSAGE_EXTRA=""
else
	AND_ARGS_FILE=""
	MESSAGE_EXTRA=""
fi

if [ -n "$BUILD_ONLY" ]; then
	if echo $REMOTE_BRANCH | grep -q master ; then
		DO_BRANCH=""
		echo "Tagging Build #$NEXT_BUILD"
	else
		echo "ERROR: build numbers are only for the master/mainline branch" 1>&2
		git rm -f $build_file
		exit 1
	fi
	echo $NEXT_BUILD > $build_file
	git add $build_file
else
	if [ -e "$build_file" ]; then
		if echo $REMOTE_BRANCH | grep -q master ; then
			echo $NEXT_BUILD > $build_file
			git add $build_file
		else
			git rm -f $build_file
		fi
		AND_BUILD_FILE=$build_file
	fi

# on master branch, or wanting to further-refine... must make a remote branch
if [ "$DO_BRANCH" == "default" ]; then
	if [ "$TAG_MAINLINE" != "true" ] && echo $REMOTE_BRANCH | grep -q master ; then
		DO_BRANCH="true"
	else
		DO_BRANCH=""
		DO_BRANCH2="false"
	fi
fi

# if no version file exists, make one that contains "1"
[ -e "$version_file" ] || echo 1 > $version_file
VERSION=$(cat "$version_file")

#iff there is no period in the present version number, treat it as a mainline (MAJOR) number (1,2,3,4)
if echo $VERSION | grep -q '\.' ; then
	#treat it as a sub-version (e.g. 3.1.2)
	if [ "$DO_BRANCH2" == "true" ]; then
		# discard least significant digit & increment the next-to-least
		SMALLEST=$(echo $VERSION | rev | cut -f2 -d. | rev)
		PREFIX=$(echo $VERSION | rev | cut -f3- -d. | rev)
		BRANCH_VERSION="$(echo $VERSION | rev | cut -f2- -d. | rev)"
	else
		#just increment the last decimal value... whatever that is.
		SMALLEST=$(echo $VERSION | rev | cut -f1 -d. | rev)
		PREFIX=$(echo $VERSION | rev | cut -f2- -d. | rev)
		BRANCH_VERSION="$VERSION"
	fi

  #if it ends in a period, increment that trailing period into a zero (so I guess "2." -> "2.-1"?) ha ha...
  if [ -z "$SMALLEST" ]; then
    SMALLEST=0
  else
    let SMALLEST=$SMALLEST+1
  fi

	if [ "$DO_BRANCH2" == "true" ]; then
		# End with a period so that the next tag will not clobber our general incrementation.
		if [ -z "$PREFIX" ]; then
			NEXT_VERSION=${SMALLEST}.
		else
			NEXT_VERSION=${PREFIX}.${SMALLEST}.
		fi
	else
		NEXT_VERSION=${PREFIX}.${SMALLEST}
	fi
else
  #no period... just increment the whole number
  let NEXT_VERSION=${VERSION}+1
  BRANCH_VERSION="$VERSION"
fi

echo "Branch: $BRANCH"
echo "From version : $VERSION"
echo "To   version : $NEXT_VERSION"

if [ -n "$ARGS" ]; then
	echo -e "\nExtra args: $ARGS"
	sleep 3
fi

# endif - not build-only
fi

git fetch

TEMP=$(mktemp /tmp/git-release.XXXXXXXX)

if [ "$DO_BRANCH" == "true" ]; then

  # if we are trying to branch BEFORE the first release, they are not following the release method;
  # this would surely generate confusion
	if grep '\.$' $version_file ; then
		git checkout "$version_file" $AND_BUILD_FILE $AND_ARGS_FILE
		fatal "do not branch from a release branch before first release commit (commit ${VERSION}0 first!)"
	fi

	NEW_BRANCH_NAME=${branch_prefix}${BRANCH_VERSION}
	echo "New branch    : $NEW_BRANCH_NAME"

  # @bug: need to check for non-version/uncommited changes (there are 'reset --hard' steps in recovery)
  #set -x

# (0) - run any pre-version hook we might find
	[ -x ".version.pre-branch" ]   && . ./.version.pre-branch
	[ -x "version/pre-branch.sh" ] && . ./version/pre-branch.sh

# (0.5) check to see if our target branch is already created (someone else released this version)
	if git branch -r | grep $NEW_BRANCH_NAME ; then
		# TODO: might be nice to setup the remote version branches in the local repo.
		git checkout "$version_file" $AND_BUILD_FILE $AND_ARGS_FILE
		fatal "branch named '$NEW_BRANCH_NAME' already in remote repo?!"
	fi

# (0.75) make a checkpoint that we can fall-back to (complete with working tree modifications)
	git stash save

# (1) - make a local branch to remember where the branches are forking (will balk at a failed/aborted release-attempt)
  git branch release-attempt

# (2) - make a version-number-advancing-commit on the mainline (will automatically balk at two competing releases)
  echo $NEXT_VERSION > $version_file
  git add $version_file $AND_BUILD_FILE $AND_ARGS_FILE
  git commit -m "$NEW_BRANCH_NAME branched off" $version_file $AND_BUILD_FILE

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

# (3.75) - remove the enumerated build numbers from the new branch
	[ -e $build_file ] && git rm -f $build_file

	if [ "$DO_BRANCH2" == "true" ]; then
		# (4) - only commit to this branch if there is something commit-worthy (removing build file)
		#       otherwise the version number stays the same.
		if [ -n "$AND_ARGS_FILE$AND_BUILD_FILE" ]; then
			git commit -m "$NEW_BRANCH_NAME branch${MESSAGE_EXTRA}" $AND_ARGS_FILE $AND_BUILD_FILE
		fi
	else
# (4) - commit to this new branch a new version file indicating a pre-release (ends in a period)
  echo ${VERSION}. > "$version_file"
  git add $version_file $AND_ARGS_FILE
  git commit -m "v: pre-${release_prefix}${VERSION}.0" $version_file $AND_ARGS_FILE $AND_BUILD_FILE
	fi

# (5) - push the new branch to the server, along with the just-branched commit
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $NEW_BRANCH_NAME > $TEMP 2>&1 ; then
	if egrep -iq '(later|defer)' $TEMP ; then
		echo " $NEW_BRANCH_NAME branch creation deferred, continuing..."
	else
	  echo "ERROR: branch creation request failed" 1>&2
	  # Our first step (branch creation) failed. So to recover, reset the current branch to 'release-attempt' (and delete the same)
	  git stash pop
	  git branch -D release-attempt
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi

# (6) - now we have a reasonable degree of certainity that the branch was accepted, push the mainline commit
#       we made earlier at step (2), which advances the version number on the "mainline" (or sub-branch)
	if [ -n "$DO_PUSH" ] && ! git push $REMOTE $BRANCH:$MERGE > $TEMP 2>&1 ; then
		if egrep -iq '(later|defer)' $TEMP ; then
			echo " $BRANCH commit deferred, continuing..."
		else
			echo "ERROR: branch creation succeeded, but mainline commit failed" 1>&2
			# To recover, swap the placement of $BRANCH & release-attempt to be more logical
			NEW_HASH=$(git rev-parse HEAD)
			git checkout -f release-attempt
			git reset --hard $NEW_HASH
			git checkout $BRANCH
			git stash pop
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
	git stash drop

# (8) - run any post-version hook we might find
	[ -x ".version.post-branch" ]   && . ./.version.post-branch
	[ -x "version/post-branch.sh" ] && . ./version/post-branch.sh

	if [ "$DO_BRANCH2" == "true" ]; then
		git checkout $BRANCH
		date
		echo
		echo "Success, $NEW_BRANCH_NAME branched off."
		echo " * you can switch to the created branch using 'git checkout $NEW_BRANCH_NAME'"
	else
  date
  echo
  echo "Success, NOW ON BRANCH $NEW_BRANCH_NAME."
  echo " * release again to tag a specific version on this branch"
  echo " * switch back to the former branch with 'git checkout $BRANCH'"
	fi
  rm -f $TEMP
  exit 0
else
  # we are NOT making a release-branch, but a release-commit... for this we advance the version_file by one and place/push a tag
  # first, some minor branch-name enforcement. Make sure the current branch-name jives with the version number...

  #easy... what follows the string "version-"; modify if not using version-* pattern (e.g. "v*" @ kernel.org)
	BRANCH_VERSION=$(echo $REMOTE_BRANCH | cut -f2 -d-)

	if [ -n "$BUILD_ONLY" ]; then
		SHORT="b$NEXT_BUILD"
		MSG="v: $SHORT${MESSAGE_EXTRA}"
		NAME="build/$NEXT_BUILD"
		AND_VERSION_FILE=""
		# (0.0) - run any pre-version hook we might find
		[ -x ".version.pre-build" ]   && . ./.version.pre-build
		[ -x "version/pre-build.sh" ] && . ./version/pre-build.sh
	else
		AND_VERSION_FILE="$version_file"

		# (0.0) - run any pre-version hook we might find
		[ -x ".version.pre-release" ]   && . ./.version.pre-release
		[ -x "version/pre-release.sh" ] && . ./version/pre-release.sh

		echo $NEXT_VERSION > "$version_file"
		NAME=${release_prefix}${NEXT_VERSION}
		MSG="${NAME}${MESSAGE_EXTRA}"
		SHORT=$NAME
	fi

	# (0) - run any pre-tag hook we might find
	[ -x ".version.pre-tag" ]   && . ./.version.pre-tag
	[ -x "version/pre-tag.sh" ] && . ./version/pre-tag.sh

	OLD_HASH=$(git rev-parse HEAD)

  #NB: this commit is for the version file (other work-area/unmerged/unsaved changes are ignored)
  git commit -m "$MSG" $AND_VERSION_FILE $AND_BUILD_FILE $AND_ARGS_FILE
  git tag -m "$NAME" "$NAME"
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $BRANCH > $TEMP 2>&1 ; then
	if egrep -iq '(later|defer)' $TEMP ; then
	  echo " $BRANCH commit deferred, continuing..."
	else
	  echo "$BRANCH commit was rejected, this probably means that your repo is not up-to-date with the server." 1>&2
	  # 'rollback' the version comming & revert the .version file
	  # *hopefully* this will not interfere with any dirty files
	  # if it does, we'll need to use the 'stash' mechanism.
	  git reset $OLD_HASH
	  git checkout "$version_file" $AND_BUILD_FILE $AND_ARGS_FILE
	  tail  $TEMP
  	  rm -f $TEMP
	  exit 1
	fi
  fi

	# Now that we are reasonably sure that the in-branch commit was recorded, we'll push the same hash to the tag.
  if [ -n "$DO_PUSH" ] && ! git push $REMOTE $NAME > $TEMP 2>&1 ; then
	if egrep -iq '(later|defer)' $TEMP ; then
	  echo " $NAME tag commit defered, continuing..."
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

	if [ -n "$BUILD_ONLY" ]; then
		# (3.5) - run any post-build-tag hook we might find
		[ -x ".version.post-build" ]   && . ./.version.post-build
		[ -x "version/post-build.sh" ] && . ./version/post-build.sh
	else
		# (3.5) - run any post-version-tag hook we might find
		[ -x ".version.post-release" ]   && . ./.version.post-release
		[ -x "version/post-release.sh" ] && . ./version/post-release.sh
	fi

	echo
	echo "Success, $NAME tagged"
  rm -f $TEMP
  exit 0
fi
