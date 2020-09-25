#set -x

BACKUP_LOCATION=/mnt/user/backup
NUM_DAILY=7
ONEDRIVE_LOCATION=onedrive:unraid/backup
DEFAULT_TIMEOUT=30
DRYRUN=""
PROGRESS="--info=progress2"
EXCLUDE=(profile/lock fail2ban/filter.d www/Dashboard Plex?Media?Server/Cache Plex?Media?Server/Media Plex?Media?Server/Metadata data/metadata www/nextcloud home/.icons profile/cache2 cache2/entries log/ Log/ logs/ Logs/ '*.log' log.txt '*.log.*' cache/ Caches/ '*.pid' '*.sample' '*.lock')
EXCLUDEPRE=('*.db' '*.xml' '*.dat' '*.dat.old' '*.db-*' '*.ini' '*.conf' '*.json' '*.ejs' BT_backup/ databases/ '*.sqlite*' '*.sqlite')

now=$(date +"%Y-%m-%d")
create_only=0
dry_run=0
verbose=0

while getopts "h?cfdv" opt; do
    case "$opt" in
    h | \?)
        echo Showing Help
        exit 0
        ;;
    c)
        create_only=1
        ;;
    d)
        dry_run=1
        DRYRUN="--dry-run"
        ;;
    v)
        verbose=1
        PROGRESS="--progress"
        ;;
    #f) 
        #output_file=$OPTARG
        #;;
    esac
done

containers=$(sudo docker ps -a | awk '{if(NR>1) print $NF}')

exclude_opts=()
for item in "${EXCLUDE[@]}"; do
    exclude_opts+=(--exclude "$item")
done

exclude_opts_pre=${exclude_opts[@]}
for item in "${EXCLUDEPRE[@]}"; do
    exclude_opts_pre+=(--exclude "$item")
done

backup_docker() {
    local TIMEOUT=$DEFAULT_TIMEOUT
    local D_NAME=$1
    local T_PATH=$BACKUP_LOCATION/Docker/$D_NAME
    local D_PATH=$T_PATH/Live
    local BACKUP="true"
    local FORCESTART="false"
    local EXCLUDES=""

    [ "$1" == "" ] && echo Docker is a required param && return

    [ ! -d $T_PATH ] && mkdir -p $T_PATH
    [[ "$create_only" == "1" || "$dry_run" == "1" ]] && docker inspect $D_NAME >$T_PATH/$D_NAME-dockerconfig.json

    local S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | grep -i $D_NAME | head -1 | cut -f 2 -d \" | tr -d '\n')
    if [ "$S_PATH" == "" ]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | head -1 | cut -f 2 -d \" | tr -d '\n')
    fi

    if [ "$create_only" == 1 ]; then
        echo ------------ $D_NAME ----------------      
    fi

    [ ! -d $S_PATH ] && echo Could not find $S_PATH && return
    [ "$S_PATH" == "" ] && echo Could not find a source path for $D_NAME && return

    [ ! -d $D_PATH ] && mkdir -p $D_PATH

    if [ ! -f $T_PATH/backup.config ]; then
        touch $T_PATH/backup.config
    fi

    local BACKUPCONFIG=$(cat $T_PATH/backup.config 2>/dev/null | egrep -v ^# | egrep -v ^$)
    if [ "$BACKUPCONFIG" == "" ]; then
        echo \# docker timeout before force kill. Set to 0 to not stop the docker when backing it up >$T_PATH/backup.config
        echo \#TIMEOUT=30 >>$T_PATH/backup.config
        echo "" >>$T_PATH/backup.config
        echo \#false will prevent the docker from being backed up. Default True >>$T_PATH/backup.config
        echo \#BACKUP=\"false\" >>$T_PATH/backup.config
        echo "" >>$T_PATH/backup.config
        echo \#true will start the docker even if it wasnt running when the backup started >>$T_PATH/backup.config
        echo \#FORCESTART=\"true\" >>$T_PATH/backup.config
        echo "" >>$T_PATH/backup.config
        echo \#Per Docker Excludes >>$T_PATH/backup.config
        echo \#EXCLUDES=\(fail2ban/filter.d Plex?Media?Server/Cache \'*.tmp\'\) >>$T_PATH/backup.config
    else
        echo Loading Variables from $T_PATH/backup.config
        . $T_PATH/backup.config
    fi

    if [ "$create_only" == 1 ]; then        
        echo $T_PATH/backup.config was created.
        return
    fi

    local pre_excludes=${exclude_opts_pre[@]}
    local full_excludes=${exclude_opts[@]}
    

    if [ ! "$EXCLUDES" == "" ]; then

        for item in "${EXCLUDES[@]}"; do
            pre_excludes+=(--exclude "$item")            
        done
        for item in "${EXCLUDES[@]}"; do
            full_excludes+=(--exclude "$item")
        done

    fi

    [ ! "$BACKUP" == "true" ] && echo Skipping Docker $D_NAME && return

    local A_PATH=$T_PATH/Archive
    local A_FILE=$A_PATH/$D_NAME-${now}.tgz
    local RUNNING=$(docker container inspect -f '{{.State.Running}}' $D_NAME)
    
    echo =================================================================
    echo Docker: $D_NAME [Start Time: $(date)]
    echo =================================================================
    printf "Dest Path: \t $D_PATH\n"
    printf "Source Path: \t $S_PATH\n"
    printf "Archive Path: \t $A_PATH\n"
    printf "Archive File: \t $A_FILE\n"
    printf "Running: \t $RUNNING\n"
    printf "Stop Timeout: \t $TIMEOUT\n"
    # [ ! "$EXCLUDES" == "" ] && printf "EXCLUDES: \t $EXCLUDES\n"
    echo ""

    [ ! -d $A_PATH ] && [ ! "$NUM_DAILY" == "0" ] && mkdir -p $A_PATH
    
    echo PHASE 1: Backup existing files in $D_PATH to $A_FILE
    if [ -d $A_PATH ] && [ ! -f $A_FILE ] && [ -d $D_PATH ] && [ ! "$NUM_DAILY" == "0" ] && [ "$dry_run" == "0" ]; then        
        echo tar -czf $A_FILE -C $D_PATH .
        tar -czf $A_FILE -C $D_PATH .
    else
        echo PHASE 1: Skipped. NUM_DAILY [$NUM_DAILY], DRY_RUN [$DRY_RUN]
    fi
    
    echo PHASE 2: Run rsync to copy files BEFORE docker stop
    if [ "$RUNNING" == "true" ] && [ ! "$TIMEOUT" == "0" ]; then        
        [ "$verbose" == "1" ] && echo PHASE 2: rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        echo PHASE 2: Stopping $D_NAME with timeout: $TIMEOUT
        [ "$dry_run" == "0" ] && echo PHASE 2: Stopped docker $(docker stop -t $TIMEOUT $D_NAME)
    else
        echo PHASE 2: Skipped because either docker state [$RUNNING] is not running or Timeout [$TIMEOUT] specified as 0 to prevent docker stop.
    fi
    
    echo PHASE 3: Run rsync to copy files AFTER docker stop
    [ "$verbose" == "1" ] && echo PHASE 3: rsync -a $PROGRESS -h ${full_excludes[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
    rsync -a $PROGRESS -h ${full_excludes[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
    
    echo "PHASE 4: Start docker if previously running"
    if [[ ! "$FORCESTART" == "false" ]] || [[ "$RUNNING" == "true" && ! "$TIMEOUT" == "0" ]]; then
        echo PHASE 4: Starting $D_NAME
        [ "$dry_run" == "0" ] && echo PHASE 4: Started docker $(docker start $D_NAME)
    else
        echo PHASE 4: Skipped.. FORCESTART [$FORCESTART], RUNNING [$RUNNING], TIMEOUT [$TIMEOUT]
    fi

    [ "$dry_run" == "0" ] && [ -d $DAILY_LOCATION ] && [ ! "$NUM_DAILY" == "0" ] && find $A_PATH -mtime +${NUM_DAILY} -name '*.tgz' -delete

    echo ""
    echo End Time: $(date)
    echo =================================================================
    echo ""
}

echo ""
echo ---- Backup Started [$(date)] ----
echo ""

if [ ! "$create_only" == "1" ]; then
    if [ -d /boot ]; then
        [ ! -d $BACKUP_LOCATION/Flash ] && mkdir -p $BACKUP_LOCATION/Flash
        [ "$verbose" == "1" ] && echo rsync -a -h --delete $PROGRESS $DRYRUN /boot $BACKUP_LOCATION/Flash
        rsync -a -h --delete $PROGRESS $DRYRUN /boot $BACKUP_LOCATION/Flash
        [ "$dry_run" == "0" ] && mv $BACKUP_LOCATION/Flash/boot/config/super.dat $BACKUP_LOCATION/Flash/boot/config/super.dat.CA_BACKUP
    fi
fi

for container in $containers; do
    backup_docker $container
done

if [[] "$create_only" == "1" || "$dry_run" == "1" ]]; then
    exit
fi

echo ---- Backup Complete [$(date)] ----

echo ""
echo "---- Starting Onedrive upload [$(date)] ----"
[ "$verbose" == "1" ] && echo rclone sync -v --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
/usr/sbin/rclone sync -v --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
echo "---- Onedrive upload Complete [$(date)] ----"
echo ""

#/usr/sbin/rclone sync -v --transfers 16 --fast-list --progress --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
#/usr/sbin/rclone sync -v /mnt/user/CommunityApplicationsAppdataBackup/ onedrive:unraid/backup

#!/bin/bash Plex docker stuff
# rsync plex files to backup location first, minimize delay on second run with docker stopped
#rsync -a --progress -h --delete /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/ /mnt/user/backup/plexbackup/Plug-in\ Support/

# stop docker, rsync plex files again, start docker
#docker stop -t 120 plex
#rsync -a --progress -h /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/ /mnt/user/backup/plexbackup/Plug-in\ Support/
#rsync -a --progress -h /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml /mnt/user/backup/plexbackup/
#docker start plex
