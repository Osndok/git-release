#!/bin/bash
#
# Copyright 2011, Robert Hailey <git@osndok.com>
#

DIR=$(dirname $0)

$DIR/release.sh --build-only "$@"

