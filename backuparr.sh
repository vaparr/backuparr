#!/bin/bash
#set -x
SECONDS=0
BACKUP_LOCATION=/mnt/user/backup
NUM_DAILY=3
ONEDRIVE_LOCATION=""
DEFAULT_TIMEOUT=30
DRYRUN=""
PROGRESS="--info=progress2"
EXCLUDE=(profile/lock log/ Log/ logs/ Logs/ '*.log' log.txt '*.log.*' '*.pid' '*.sample' '*.lock' /lock)
EXCLUDEPRE=('*.db' '*.xml' '*.dat' '*.dat.old' '*.db-*' '*.ini' '*.conf' '*.json' '*.ejs' BT_backup/ databases/ '*.sqlite*' '*.sqlite')

script_path=$(dirname $(realpath -s $0))
is_user_script=0
now=$(date +"%Y-%m-%d")
create_only=0
dry_run=0
verbose=0
skip_onedrive=0
docker_name=""
STOPPED_DOCKER=""
archive_backups=0

while getopts "h?cufdvsan:b:o:y:" opt; do
    case "$opt" in
    h | \?)
        echo Options:
        echo "-d : Dry Run"
        echo "-v : Verbose"
        echo "-s : Skip OneDrive Upload"
        echo "-a : Archive live backup to tgz (configure ARCHIVE_DAYS in DockerName-backup.conf)"
        echo "-c : Create Backup.config files only"
        echo "-n [docker] : Only backup this single docker"
        echo "-u : Use when calling from Unraid User.Scripts to adjust output to not flood logs"
        echo "-b : Backup location"
        echo "-o : OneDrive location (configure in rclone)"
        echo "-y : Sets the number of archive days. Defaults to 3, can be overridden in .conf"
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
    a)
        archive_backups=1
        ;;
    u)
        is_user_script=1
        ;;
    n)
        docker_name=${OPTARG}
        ;;
    b)
        BACKUP_LOCATION=${OPTARG}
        ;;
    y)
        NUM_DAILY=${OPTARG}
        ;;
    o)
        ONEDRIVE_LOCATION=${OPTARG}
        ;;
        #f)
        #output_file=$OPTARG
        #;;
    esac
done

function converttime() {
    ((m = (${1} % 3600) / 60))
    ((s = ${1} % 60))
    printf "%02d minutes, %02d seconds" $m $s
}

trap 'ExitFunc' exit SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT
SUCCESS="false"
function ExitFunc() {
    local time_m=$(converttime $SECONDS)

    if [[ ! "$STOPPED_DOCKER" == "" ]]; then
        docker start $STOPPED_DOCKER &
    fi

    if [[ ! "$SUCCESS" == "true" ]]; then
        NotifyError "[Backuparr exited]" "Script exited abnormally after $time_m."
        exit 255
    else
        NotifyInfo "[Backuparr exited]" "Script exited normally after $time_m."
        exit 0
    fi

}

trap 'ShouldExit' return
function ShouldExit() {

    pid=$(cut -d' ' -f4 < /proc/$$/stat)
  # echo "PPID: $PPID pid: $pid"

    if [[ "$PPID" != "$pid" ]]; then 
       echo "Parent has died. Exiting."
       ExitFunc
    fi
}
function NotifyInfo() {
    if [[ $is_user_script = 1 ]]; then
        /usr/local/emhttp/webGui/scripts/notify -e "[Backuparr]" -s "$1" -d "$2" -i "normal"
    fi
    echo $1 - $2
}

function NotifyError() {
    if [[ $is_user_script = 1 ]]; then
        /usr/local/emhttp/webGui/scripts/notify -e "[Backuparr]" -s "$1" -d "$2" -i "alert"
    fi
    echo [ERROR] $1 - $2
}

function LogInfo() {
    echo "$@"
    ShouldExit
}

function LogVerbose() {
    [ "$verbose" == "1" ] && echo "$@"
    ShouldExit
}

function LogWarning() {
    echo "[WARNING] $@"
    ShouldExit
}

function LogError() {
    echo "[ERROR] $@"
    NotifyError "Backuparr Error" "$@"
}

function stop_docker() {
    local op="[DOCKER STOP]"
    local stop_seconds=$SECONDS
    LogInfo $op: STOPPING $1 with timeout: $2
    local RUNNING=$(docker container inspect -f '{{.State.Running}}' $1)

    if [[ "$RUNNING" == "false" ]]; then
        LogInfo $op: Docker is already stopped!
        return
    fi

    if [ "$dry_run" == "0" ]; then
        STOPPED_DOCKER=$1
        LogInfo $op: STOPPED docker $(docker stop -t $2 $1) in $((SECONDS - $stop_seconds)) Seconds
    else
        return
    fi
    RUNNING=$(docker container inspect -f '{{.State.Running}}' $1)

    if [[ "$RUNNING" == "false" ]]; then
        LogVerbose $op: Docker Stopped Successfully
    else
        LogWarning $op: Docker not stopped.
        docker stop -t 600 $1
    fi
}

function start_docker() {
    local op="[DOCKER START]"
    local start_seconds=$SECONDS
    LogInfo $op: STARTING $1
    local RUNNING=$(docker container inspect -f '{{.State.Running}}' $1)
    if [[ "$RUNNING" == "true" ]]; then
        LogInfo $op: Docker is already started!
        return
    fi
    if [ "$dry_run" == "0" ]; then
        LogInfo $op: STARTED docker $(docker start $1) in $((SECONDS - $start_seconds)) Seconds
        STOPPED_DOCKER=""
    else
        return
    fi
    RUNNING=$(docker container inspect -f '{{.State.Running}}' $1)
    if [[ "$RUNNING" == "true" ]]; then
        LogVerbose $op: Docker Started Successfully
    else
        LogWarning $op: Docker not started.
        docker start $1
    fi

}

function create_config() {
    local op="[CONFIG]"
    [[ "$dry_run" == "1" ]] && LogInfo "$op: Skipping config create in DryRun" && return

    [ ! -d $T_PATH ] && mkdir -p $T_PATH

    local BACKUPCONFIG=$(cat $T_PATH/$CONF_NAME 2>/dev/null | egrep -v ^\# | egrep -v ^$)
    if [ "$BACKUPCONFIG" == "" ]; then
        if [ -f "$script_path/sample-configs/$CONF_NAME" ]; then
            cp -f $script_path/sample-configs/$CONF_NAME $T_PATH/$CONF_NAME
            . $T_PATH/$CONF_NAME
        else
            cp -f $script_path/sample-configs/default-backup.conf $T_PATH/$CONF_NAME
        fi
    else
        LogInfo $op: Load Variables from $T_PATH/$CONF_NAME
        LogInfo ""
        . $T_PATH/$CONF_NAME
    fi

    if [ "$create_only" == 1 ]; then
        if [ -f "$script_path/sample-configs/$CONF_NAME" ]; then
            cp -u $script_path/sample-configs/$CONF_NAME $T_PATH/$CONF_NAME
        else
            cp -u $script_path/sample-configs/default-backup.conf $T_PATH/$CONF_NAME
        fi

        LogInfo $op: $T_PATH/$CONF_NAME was created.
        return
    fi
}

function archive_docker() {
    local op="[ARCHIVE]"
    [[ "$ARCHIVE_DAYS" == "0" ]] && ARCHIVE_DAYS=1

    [ ! -d $A_PATH ] && mkdir -p $A_PATH

    [ "$dry_run" == "0" ] && [ -d $A_PATH ] && find $A_PATH -mtime +${ARCHIVE_DAYS} -name '*.tgz' -delete

    LogInfo $op: Archiving to $A_FILE. This may take some time...
    if [ -d $A_PATH ] && [ ! -f $A_FILE ] && [ -d $D_PATH ]; then
        LogVerbose $op: tar -czf $A_FILE -C $D_PATH .
        if [[ "$dry_run" == "0" ]]; then
            tar -czf $A_FILE -C $D_PATH .
            if [[ $? -ne 0 ]]; then
                LogError "$op: tar failed"
            fi
        fi
    else
        [ -f $A_FILE ] && LogInfo $op: Skipped. Archive exists for $now.
        [ ! -f $A_FILE ] && LogInfo $op: Skipped. NUM_DAILY [$ARCHIVE_DAYS]
    fi
}

function backup_docker() {
    local op="[BACKUP DOCKER]"
    local START_TIME=$SECONDS
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

    create_config

    [[ "$create_only" == "1" ]] && return

    docker inspect $D_NAME >$T_PATH/$D_NAME-dockerconfig.json

    local S_PATH=""
    if [ -d "/mnt/cache/appdata/$D_NAME" ]; then        
        S_PATH="/mnt/user/appdata/$D_NAME"
        LogInfo "Using $S_PATH as backup source"
    fi
    
    if [ "$S_PATH" == "" ]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | grep -i $D_NAME | head -1 | cut -f 2 -d \" | tr -d '\n')
    fi
    
    if [ "$S_PATH" == "" ]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata/ | head -1 | cut -f 2 -d \" | tr -d '\n')
    fi

    [ ! -d $S_PATH ] && LogWarning "Could not find $S_PATH" && echo && return
    [ "$S_PATH" == "" ] && LogWarning "Could not find a source path for $D_NAME" && echo && return

    [ ! -d $D_PATH ] && mkdir -p $D_PATH

    touch $D_PATH
    
    local pre_excludes=${exclude_opts_pre[@]}
    local full_excludes=${exclude_opts[@]}

    if [ ! "$EXCLUDES" == "" ]; then
        for item in "${EXCLUDES[@]}"; do
            pre_excludes+=(--exclude "$item")
            full_excludes+=(--exclude "$item")
        done
    fi

    [ ! "$BACKUP" == "true" ] && LogInfo $op: Skipping Docker $D_NAME && return

    local A_PATH=$T_PATH/Archive
    local A_FILE=$A_PATH/$D_NAME-${now}.tgz
    local RUNNING=$(docker container inspect -f '{{.State.Running}}' $D_NAME)

    printf "Dest Path: \t $D_PATH\n"
    printf "Source Path: \t $S_PATH\n"
    [ "$archive_backups" == "1" ] && printf "Archive Path: \t $A_PATH\n"
    [ "$archive_backups" == "1" ] && printf "Archive File: \t $A_FILE\n"
    printf "Running: \t $RUNNING\n"
    printf "Stop Timeout: \t $TIMEOUT\n"
    [ ! "$EXCLUDES" == "" ] && printf "Excludes: \t (${EXCLUDES[*]})\n"
    echo ""

    LogInfo $op: RSYNC Run 1 - Run rsync to copy files BEFORE docker stop
    if [ "$RUNNING" == "true" ] && [ ! "$TIMEOUT" == "0" ]; then
        LogVerbose $op: rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        rsync -a $PROGRESS -h ${pre_excludes[@]} $DRYRUN $S_PATH/ $D_PATH/
        if [[ $? -ne 0 ]]; then
            LogWarning $op: RSYNC RUN 1 Failed
        fi
        stop_docker $D_NAME $TIMEOUT
    else
        LogInfo $op: Skipped Docker Stop because either docker state [$RUNNING] is not running or Timeout [$TIMEOUT] is 0.
    fi

    LogInfo $op: RSYNC RUN 2 - Run rsync to copy files AFTER docker stop
    LogVerbose $op: rsync -a $PROGRESS -h ${full_excludes[@]} --delete --delete-excluded $DRYRUN $S_PATH/ $D_PATH/
    rsync -a $PROGRESS -h ${full_excludes[@]} --delete --delete-excluded $DRYRUN $S_PATH/ $D_PATH/
    if [[ $? -ne 0 ]]; then
        LogError "$op: RSYNC RUN 2 Failed"
    fi

    LogInfo "$op: Start docker if previously running, autostart is enabled, or forcestart is true"

    local autostart=$(cat /var/lib/docker/unraid-autostart | cut -f 1 -d " " | egrep "^${D_NAME}$")
    LogVerbose $op: autostart = $autostart
    if [[ ! "$FORCESTART" == "false" ]] || [[ "$autostart" == "$D_NAME" ]] || [[ "$RUNNING" == "true" && ! "$TIMEOUT" == "0" ]]; then
        start_docker $D_NAME
    else
        LogInfo $op: Docker Start Skipped. FORCESTART [$FORCESTART], RUNNING [$RUNNING], TIMEOUT [$TIMEOUT]
    fi

    [ "$archive_backups" == "1" ] && archive_docker

    echo ""
    echo End Time: $(date) [Elapsed $((SECONDS - $START_TIME)) Seconds]
    echo =================================================================
    echo ""
}

# flash drive backup
function BackupFlash() {
    local op="[BACKUP FLASH]"

    if [[ ! "$create_only" == "1" && "$docker_name" == "" ]]; then
        LogInfo $op: Starting Flash Backup...
        if [[ ! "$dry_run" == "0" ]]; then
            LogInfo "$op: Skipping /usr/local/emhttp/webGui/scripts/flash_backup in dry run"
        else
            backup_file=$(/usr/local/emhttp/webGui/scripts/flash_backup)
            if [[ $? -ne 0 ]]; then
                LogError "$op: flash_backup failed"
            fi

            if [ -f /$backup_file ]; then
                mkdir -p $BACKUP_LOCATION/Flash
                mv /$backup_file $BACKUP_LOCATION/Flash
                find $BACKUP_LOCATION/Flash -mtime +${NUM_DAILY} -name '*.zip' -delete
            fi
        fi
        LogInfo $op: Flash Backup completed.
    fi
}

function GetDockerList() {

    local containers=""

    if [[ -f /boot/config/plugins/dockerMan/userprefs.cfg ]]; then
        containers=$(cat /boot/config/plugins/dockerMan/userprefs.cfg | cut -f 2 -d \" | egrep -v "\-folder$")
    fi
    local containers_from_docker=$(docker ps -a | awk '{if(NR>1) print $NF}' | sort -f)

    if [[ "$containers" != "" ]]; then
        echo $containers
        for container_from_docker in $containers_from_docker; do
            local already_found=$(echo $containers | egrep $container_from_docker)
            if [ "$already_found" == "" ]; then
               echo $container_from_docker
            fi
        done
    else
       echo $containers_from_docker
    fi


}


echo ""
echo "---- Backup Started [$(date)] ----"
echo ""

# exclude options, RSYNC2
exclude_opts=()
for item in "${EXCLUDE[@]}"; do
    exclude_opts+=(--exclude "$item")
done

# exclude options, RSYNC1
exclude_opts_pre=${exclude_opts[@]}
for item in "${EXCLUDEPRE[@]}"; do
    exclude_opts_pre+=(--exclude "$item")
done

BackupFlash

# docker backup


if [[ "$docker_name" == "" ]]; then
    for container in $(GetDockerList); do
        backup_docker $container
    done
else
    container=$(docker ps -a | awk '{if(NR>1) print $NF}' | egrep -i ^$docker_name$)
    if [[ ! "$container" == "" ]]; then
        backup_docker $container
    else
        LogWarning Could not find $docker_name. Run docker ps -a command to check.
        echo
    fi
fi

echo "---- Backup Complete [$(date)] ----"
echo ""

if [[ "$create_only" == "1" || "$dry_run" == "1" || "$skip_onedrive" == "1" || "$ONEDRIVE_LOCATION" == "" ]]; then
    SUCCESS="true"
    exit
fi

echo "---- Starting Onedrive upload [$(date)] ----"
echo ""
op="[RCLONE]"
RCLONE="/usr/sbin/rclone sync --exclude Live/** --onedrive-chunk-size 70M --retries 3 --checkers 16 --transfers 6 --fast-list --copy-links"
if [[ $is_user_script = 1 ]]; then
    LogInfo $op: $RCLONE $BACKUP_LOCATION $ONEDRIVE_LOCATION
    LogInfo $op: rclone is working. Waiting...
    $RCLONE $BACKUP_LOCATION $ONEDRIVE_LOCATION
else
    LogVerbose $op: $RCLONE --progress $BACKUP_LOCATION $ONEDRIVE_LOCATION
    $RCLONE -v --progress $BACKUP_LOCATION $ONEDRIVE_LOCATION
fi
if [[ $? -ne 0 ]]; then
    LogError "$op: rclone failed"
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
