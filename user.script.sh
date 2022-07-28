#!/bin/bash
#arrayStarted=true
REPO_NAME=backuparr
REPO_LOCATION=/tmp/$REPO_NAME
REPO_URL=https://github.com/vaparr/$REPO_NAME.git
SCRIPT_NAME=backuparr.sh

trap "kill -- $$" exit SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT

        echo Options:
        echo "-d : Dry Run"
        echo "-v : Verbose"
        echo "-s : Skip OneDrive Upload"
        echo "-a : Archive live backup to tgz (configure ARCHIVE_DAYS in DockerName-backup.conf)"
        echo "-c : Create Backup.config files only"
        echo "-n [docker] : Only backup this single docker"
        echo "-u : Use when calling from Unraid User.Scripts to adjust output to not flood logs"
        echo "-b : Backup location (Default: /mnt/user/backup)"
        echo "-o : OneDrive location (configure in rclone)"
        echo "-y : Sets the number of archive days. Defaults to 3, can be overridden in .conf"

[ ! -d $REPO_LOCATION ] && mkdir -p $REPO_LOCATION && cd $REPO_LOCATION && git clone $REPO_URL
cd $REPO_LOCATION/$REPO_NAME && git fetch --all && git reset --hard origin/master && git pull --ff-only
chmod +x $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME
exec /bin/bash $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME -u -o onedrive:unraid/backup
# Example for specifying backup path: 
# exec /bin/bash $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME -u -o onedrive:unraid/backup -b /path/to/backupFolder
# This is what i use:
# exec /bin/bash $REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME -u -a
