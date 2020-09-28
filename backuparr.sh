#!/bin/bash
#set -x
SECONDS=0
BACKUP_LOCATION=/mnt/user/backup
NUM_DAILY=3
ONEDRIVE_LOCATION=onedrive:unraid/backup
DEFAULT_TIMEOUT=30
DRYRUN=""
PROGRESS="--info=progress2"
EXCLUDE=(profile/lock log/ Log/ logs/ Logs/ '*.log' log.txt '*.log.*' '*.pid' '*.sample' '*.lock' /lock)
EXCLUDEPRE=('*.db' '*.xml' '*.dat' '*.dat.old' '*.db-*' '*.ini' '*.conf' '*.json' '*.ejs' BT_backup/ databases/ '*.sqlite*' '*.sqlite')

script_path=$(dirname $(realpath -s $0))
now=$(date +"%Y-%m-%d")
create_only=0
dry_run=0
verbose=0
skip_onedrive=0
docker_name=""
STOPPED_DOCKER=""


while getopts "h?cfdvsn:" opt; do
    case "$opt" in
    h | \?)
        echo Options:
	echo "-d : Dry Run"
	echo "-v : Verbose"
	echo "-s : Skip OneDrive Upload"
	echo "-c : Create Backup.config files only"
	echo "-n [docker] : Only backup this single docker"
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
    s)
        skip_onedrive=1
        ;;
    n)
        docker_name=${OPTARG}
        ;;
    #f) 
        #output_file=$OPTARG
        #;;
    esac
done

trap 'ExitFunc' exit
SUCCESS="false"
function ExitFunc(){
    if [[ ! "$SUCCESS" == "true" ]]; then
       NotifyError "[Backuparr exited]" "Script exited abnormally after $SECONDS seconds."
    else
       NotifyInfo "[Backuparr exited]" "Script exited normally after $SECONDS seconds."
    fi

    if [[ ! "$STOPPED_DOCKER" == "" ]]; then
       docker start $STOPPED_DOCKER
    fi

}

function NotifyInfo() {
    if [[ $script_path =~ \/boot\/repos.* ]]; then # one-line stats when running from user scripts
         /usr/local/emhttp/webGui/scripts/notify -e "$1" -d "$2" -i "normal" 
    fi
    echo $1 - $2
}

function NotifyError() {
    if [[ $script_path =~ \/boot\/repos.* ]]; then # one-line stats when running from user scripts
         /usr/local/emhttp/webGui/scripts/notify -e "$1" -d "$2" -i "alert" 
    fi
    echo [ERROR] $1 - $2
}

function LogInfo() {
    echo "$@"
}

function LogVerbose() {
    [ "$verbose" == "1" ] && echo "$@"
}

function LogWarning() {
    echo "[WARNING] $@"
}

function LogError() {
   echo "[ERROR] $@"
   NotifyError "Backuparr Error" "$@"
}

backup_docker() {
    local TIMEOUT=$DEFAULT_TIMEOUT
    local D_NAME=$1
    local T_PATH=$BACKUP_LOCATION/Docker/$D_NAME
    local D_PATH=$T_PATH/Live
    local BACKUP="true"
    local FORCESTART="false"
    local EXCLUDES=""
    local CONF_NAME=$D_NAME-backup.conf
    local ARCHIVE_DAYS=$NUM_DAILY
    [ "$1" == "" ] && LogInfo Docker is a required param && return

    LogInfo =================================================================
    LogInfo Docker: $D_NAME [Start Time: $(date)]
    LogInfo =================================================================

    [ ! -d $T_PATH ] && mkdir -p $T_PATH
    [[ "$create_only" == "1" || "$dry_run" == "1" ]] && docker inspect $D_NAME >$T_PATH/$D_NAME-dockerconfig.json

    local S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | grep -i $D_NAME | head -1 | cut -f 2 -d \" | tr -d '\n')
    if [ "$S_PATH" == "" ]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | head -1 | cut -f 2 -d \" | tr -d '\n')
    fi

    [ ! -d $S_PATH ] && LogWarning "Could not find $S_PATH" && echo && return
    [ "$S_PATH" == "" ] && LogWarning "Could not find a source path for $D_NAME" && echo && return

    [ ! -d $D_PATH ] && mkdir -p $D_PATH

    if [ ! -f $T_PATH/$CONF_NAME ]; then
        touch $T_PATH/$CONF_NAME
    fi

    local BACKUPCONFIG=$(cat $T_PATH/$CONF_NAME 2>/dev/null | egrep -v ^\# | egrep -v ^$)
    if [ "$BACKUPCONFIG" == "" ]; then
        if [ -f "$script_path/sample-configs/$CONF_NAME" ]
        then
            cp -f $script_path/sample-configs/$CONF_NAME $T_PATH/$CONF_NAME
        else
            cp -f $script_path/sample-configs/default-backup.conf $T_PATH/$CONF_NAME
        fi
    else
        LogInfo PHASE 0: Load Variables from $T_PATH/$CONF_NAME
        LogInfo ""
        . $T_PATH/$CONF_NAME
    fi

    if [ "$create_only" == 1 ]; then
        if [ -f "$script_path/sample-configs/$CONF_NAME" ]
        then
            cp -u $script_path/sample-configs/$CONF_NAME $T_PATH/$CONF_NAME
        else
            cp -u $script_path/sample-configs/default-backup.conf $T_PATH/$CONF_NAME
        fi

        LogInfo $T_PATH/$CONF_NAME was created.
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

    [ ! "$BACKUP" == "true" ] && LogInfo PHASE 0: Skipping Docker $D_NAME && return

    local A_PATH=$T_PATH/Archive
    local A_FILE=$A_PATH/$D_NAME-${now}.tgz
    local RUNNING=$(docker container inspect -f '{{.State.Running}}' $D_NAME)
    
    printf "Dest Path: \t $D_PATH\n"
    printf "Source Path: \t $S_PATH\n"
    printf "Archive Path: \t $A_PATH\n"
    printf "Archive File: \t $A_FILE\n"
    printf "Running: \t $RUNNING\n"
    printf "Stop Timeout: \t $TIMEOUT\n"
    [ ! "$EXCLUDES" == "" ] && printf "Excludes: \t (${EXCLUDES[*]})\n"
    echo ""

    [ ! -d $A_PATH ] && [ ! "$ARCHIVE_DAYS" == "0" ] && mkdir -p $A_PATH
    
    LogInfo PHASE 1: Archive $D_PATH to $A_FILE
    if [ -d $A_PATH ] && [ ! -f $A_FILE ] && [ -d $D_PATH ] && [ ! "$ARCHIVE_DAYS" == "0" ] && [ "$dry_run" == "0" ]; then        
        LogVerbose PHASE 1: tar -czf $A_FILE -C $D_PATH .
        tar -czf $A_FILE -C $D_PATH .
    else
        [ -f $A_FILE ] && LogInfo PHASE 1: Skipped. Archive exists for $now.
        [ ! -f $A_FILE ] && LogInfo PHASE 1: Skipped. NUM_DAILY [$ARCHIVE_DAYS], DRY_RUN [$dry_run]
    fi
    
    LogInfo PHASE 2: Run rsync to copy files BEFORE docker stop
    if [ "$RUNNING" == "true" ] && [ ! "$TIMEOUT" == "0" ]; then        
        LogVerbose PHASE 2: rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        LogInfo PHASE 2: STOP $D_NAME with timeout: $TIMEOUT
        if [ "$dry_run" == "0" ]; then
            STOPPED_DOCKER=$D_NAME
            LogInfo PHASE 2: STOPPED docker $(docker stop -t $TIMEOUT $D_NAME)
        fi
    else
        LogInfo PHASE 2: Skipped because either docker state [$RUNNING] is not running or Timeout [$TIMEOUT] specified as 0 to prevent docker stop.
    fi
    
    LogInfo PHASE 3: Run rsync to copy files AFTER docker stop
    LogVerbose PHASE 3: rsync -a $PROGRESS -h ${full_excludes[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
    rsync -a $PROGRESS -h ${full_excludes[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
    
    LogInfo "PHASE 4: Start docker if previously running"
    if [[ ! "$FORCESTART" == "false" ]] || [[ "$RUNNING" == "true" && ! "$TIMEOUT" == "0" ]]; then
        LogInfo PHASE 4: START $D_NAME
        if [ "$dry_run" == "0" ];then
           LogInfo PHASE 4: STARTED docker $(docker start $D_NAME)
           STOPPED_DOCKER=""
        fi
    else
        LogInfo PHASE 4: Skipped. FORCESTART [$FORCESTART], RUNNING [$RUNNING], TIMEOUT [$TIMEOUT]
    fi

    [ "$dry_run" == "0" ] && [ -d $DAILY_LOCATION ] && [ ! "$ARCHIVE_DAYS" == "0" ] && find $A_PATH -mtime +${ARCHIVE_DAYS} -name '*.tgz' -delete

    echo ""
    echo End Time: $(date)
    echo =================================================================
    echo ""
}

echo ""
echo "---- Backup Started [$(date)] ----"
echo ""

# exclude options, phase 2
exclude_opts=()
for item in "${EXCLUDE[@]}"; do
    exclude_opts+=(--exclude "$item")
done

# exclude options, phase 1
exclude_opts_pre=${exclude_opts[@]}
for item in "${EXCLUDEPRE[@]}"; do
    exclude_opts_pre+=(--exclude "$item")
done

# test
# backup_docker "organizrv2"
# exit

# flash drive backup
if [[ ! "$create_only" == "1" && "$docker_name" == "" ]]; then
    LogInfo Starting Flash Backup...
    backup_file=`/usr/local/emhttp/webGui/scripts/flash_backup`
    if [ -f /$backup_file ]; then
       mkdir -p $BACKUP_LOCATION/Flash/Archive
       mv /$backup_file $BACKUP_LOCATION/Flash/Archive
       find $BACKUP_LOCATION/Flash/Archive -mtime +${NUM_DAILY} -name '*.zip' -delete
    fi
    if [ -d /boot ]; then
        [ ! -d $BACKUP_LOCATION/Flash ] && mkdir -p $BACKUP_LOCATION/Flash
        LogVerbose rsync -a -h --delete $PROGRESS $DRYRUN /boot $BACKUP_LOCATION/Flash
        rsync -a -h --delete $PROGRESS $DRYRUN /boot $BACKUP_LOCATION/Flash
        [ "$dry_run" == "0" ] && mv $BACKUP_LOCATION/Flash/boot/config/super.dat $BACKUP_LOCATION/Flash/boot/config/super.dat.CA_BACKUP
    fi
    LogInfo Flash Backup completed.
fi

# docker backup
if [[ "$docker_name" == "" ]]; then
    containers=$(docker ps -a | awk '{if(NR>1) print $NF}' | sort -f)
    for container in $containers; do
        backup_docker $container
    done
else
    container=$(docker ps -a | awk '{if(NR>1) print $NF}' | egrep -i ^$docker_name$)
    if [[ ! "$container" == "" ]]; then
        backup_docker $docker_name
    else
        LogWarning Could not find $docker_name. Run docker ps command to check.
        echo
    fi
fi

echo "---- Backup Complete [$(date)] ----"
echo ""

if [[ "$create_only" == "1" || "$dry_run" == "1" || "$skip_onedrive" == "1" ]]; then
    SUCCESS="true"
    exit
fi

echo "---- Starting Onedrive upload [$(date)] ----"
echo ""

if [[ $script_path =~ \/boot\/repos.* ]]; then # one-line stats when running from user scripts
    LogInfo rclone sync --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
    LogInfo rclone is working. Waiting...
    /usr/sbin/rclone sync --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
else
    LogVerbose rclone sync --progress --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
    /usr/sbin/rclone sync --progress --checkers 16 --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
fi

SUCCESS="true"
echo ""
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
