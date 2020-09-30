#!/bin/bash
#arrayStarted=true
REPO_NAME=backuparr
REPO_LOCATION=/tmp/$REPO_NAME
REPO_URL=https://github.com/vaparr/$REPO_NAME.git
SCRIPT_NAME=backuparr.sh

trap "kill -- $$" exit SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT

[ ! -d $REPO_LOCATION ] && mkdir -p $REPO_LOCATION && cd $REPO_LOCATION && git clone $REPO_URL
cd $REPO_LOCATION/$REPO_NAME && git pull
chmod +x $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME
exec /bin/bash $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME -u


