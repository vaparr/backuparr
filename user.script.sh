#!/bin/bash
#description=Unraid backup script
#arrayStarted=true
#name=backuparr

REPO_LOCATION=/boot/repos
REPO_NAME=backuparr
SCRIPT_NAME=backuparr.sh
REPO_URL=https://github.com/vaparr/$REPO_NAME.git

[ ! -d $REPO_LOCATION ] && mkdir -p $REPO_LOCATION && cd $REPO_LOCATION && git clone $REPO_URL
cd $REPO_LOCATION/$REPO_NAME && git pull
/bin/bash $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME