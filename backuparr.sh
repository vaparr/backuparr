#!/bin/bash
# rsync plex files to backup location first, minimize delay on second run with docker stopped
#rsync -a --progress -h --delete /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/ /mnt/user/backup/plexbackup/Plug-in\ Support/

# stop docker, rsync plex files again, start docker
#docker stop -t 120 plex
#rsync -a --progress -h /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/ /mnt/user/backup/plexbackup/Plug-in\ Support/
#rsync -a --progress -h /mnt/user/appdata/plex/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml /mnt/user/backup/plexbackup/
#docker start plex
#set -x

BACKUP_LOCATION=/mnt/user/backup
NUM_DAILY=7
ONEDRIVE_LOCATION=onedrive:unraid/backup-docker
DEFAULT_TIMEOUT=30
#DRYRUN="--dry-run"
DRYRUN=""
EXCLUDE=( www/Dashboard Server/Cache Server/Metadata Server/Media www/nextcloud home/.icons profile/cache2 cache2/entries log/ Log/ logs/ Logs/ '*.log' log.txt '*.log.*' Caches/ '*.pid' '*.sample' '*.lock' )
EXCLUDEPRE=( '*.db' '*.xml' '*.dat' '*.dat.old' '*.db-*' '*.ini' '*.conf' '*.json' '*.ejs' BT_backup/ databases/ '*.sqlite*' '*.sqlite' )
now=`date +"%Y-%m-%d"`
create_only=0
while getopts "h?cf:" opt; do
case "$opt" in
h|\?)
echo Showing Help
exit 0
;;
c) create_only=1
;;
#f) output_file=$OPTARG
#;;
esac
done

containers=$(sudo docker ps -a | awk '{if(NR>1) print $NF}')

exclude_opts=()
for item in "${EXCLUDE[@]}"; do
exclude_opts+=( --exclude "$item" )
done
exclude_opts_pre=${exclude_opts[@]}
for item in "${EXCLUDEPRE[@]}"; do
exclude_opts_pre+=( --exclude "$item" )
done


backup_docker(){
local TIMEOUT=$DEFAULT_TIMEOUT
local D_NAME=$1
local D_PATH=$BACKUP_LOCATION/$D_NAME/Live
local BACKUP="true"
local FORCESTART="false"

[ "$1" == "" ] && echo Docker is a required param && return

local S_PATH=`docker inspect -f '{{json .Mounts }}' $D_NAME | jq .[].Source | grep appdata | head -1| cut -f 2 -d \" | tr -d '\n'`
[ ! -d $S_PATH ] && echo Could not find $S_PATH && return
[ "$S_PATH" == "" ] && echo Could not find a source path for $D_NAME && return


if [ ! -f $BACKUP_LOCATION/$D_NAME/backup.config ]
then
touch $BACKUP_LOCATION/$D_NAME/backup.config
fi

local BACKUPCONFIG=`cat $BACKUP_LOCATION/$D_NAME/backup.config 2>/dev/null | egrep -v ^# | egrep -v ^$`
if [ "$BACKUPCONFIG" == "" ]
then
echo \# docker timeout before force kill. Set to 0 to not stop the docker when backing it up > $BACKUP_LOCATION/$D_NAME/backup.config
echo \#TIMEOUT=30 >> $BACKUP_LOCATION/$D_NAME/backup.config >> $BACKUP_LOCATION/$D_NAME/backup.config
echo "" >> $BACKUP_LOCATION/$D_NAME/backup.config
echo \#false will prevent the docker from being backed up. Default True >> $BACKUP_LOCATION/$D_NAME/backup.config
echo \#BACKUP=\"false\" >> $BACKUP_LOCATION/$D_NAME/backup.config
echo "" >> $BACKUP_LOCATION/$D_NAME/backup.config
echo \#true will start the docker even if it wasnt running when the backup started >> $BACKUP_LOCATION/$D_NAME/backup.config
echo \#FORCESTART=\"true\" >> $BACKUP_LOCATION/$D_NAME/backup.config
else
echo Loading Variables from $BACKUP_LOCATION/$D_NAME/backup.config
. $BACKUP_LOCATION/$D_NAME/backup.config

fi

if [ $create_only == 1 ]
then
echo ------------ $D_NAME ----------------
echo $BACKUP_LOCATION/$D_NAME/backup.config was created.
return
fi


[ ! "$BACKUP" == "true" ] && echo Skipping Docker $D_NAME && return

local A_PATH=$BACKUP_LOCATION/$D_NAME/Archive
local A_FILE=$A_PATH/$D_NAME-${now}.tgz


local RUNNING=`docker container inspect -f '{{.State.Running}}' $D_NAME`


echo ""
echo ========================================
echo Docker Name: $D_NAME
echo Dest Path: $D_PATH
echo Source Path: $S_PATH
echo Archive Path: $A_PATH
echo Archive FileName: $A_FILE
echo Running: "$RUNNING"
echo Docker Timeout: $TIMEOUT
echo ========================================

[ ! -d $A_PATH ] && [ ! $NUM_DAILY == "0" ] && mkdir -p $A_PATH
if [ -d $A_PATH ] && [ ! -f $A_FILE ] && [ -d $D_PATH ] && [ ! $NUM_DAILY == "0" ]
then
echo
echo Backing up existing files in $D_PATH to $A_FILE
echo tar -czf $A_FILE -C $D_PATH .
tar -czf $A_FILE -C $D_PATH .
fi

[ ! -d $D_PATH ] && mkdir -p $D_PATH

docker inspect $D_NAME > $BACKUP_LOCATION/$D_NAME/$D_NAME-dockerconfig.json

if [ $RUNNING == "true" ] && [ ! $TIMEOUT == "0" ]
then
echo rsync -a --progress -h ${exclude_opts_pre[@]} $DRYRUN $S_PATH/ $D_PATH/

rsync -a --progress -h ${exclude_opts_pre[@]} $DRYRUN $S_PATH/ $D_PATH/
echo Stopping $D_NAME with timeout: $TIMEOUT
echo stopped docker `docker stop -t $TIMEOUT $D_NAME`
else
echo Skipping Docker Stop
fi
echo rsync -a --progress -h ${exclude_opts[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
rsync -a --progress -h ${exclude_opts[@]} --delete $DRYRUN $S_PATH/ $D_PATH/
if [[ ! "$FORCESTART" == "false" ]] || [[ $RUNNING == "true" && ! $TIMEOUT == "0" ]]
then
echo Starting $D_NAME
echo started docker `docker start $D_NAME`
fi

[ -d $DAILY_LOCATION ] && [ ! $NUM_DAILY == "0" ] && find $A_PATH -mtime +${NUM_DAILY} -name '*.tgz' -delete


}

backup_docker Firefox
exit

if [ ! $create_only == "1" ]
then
if [ -d /boot ]
then
[ ! -d $BACKUP_LOCATION/Flash ] && mkdir -p $BACKUP_LOCATION/Flash
rsync -a -h --delete --progress /boot $BACKUP_LOCATION/Flash
mv $BACKUP_LOCATION/Flash/config/super.dat $BACKUP_LOCATION/Flash/config/super.dat.CA_BACKUP
fi
fi

for container in $containers
do
backup_docker $container
done

echo ---- Backup Complete ---

exit
echo "Starting Onedrive upload"
/usr/sbin/rclone sync -v --transfers 16 --fast-list --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
#/usr/sbin/rclone sync -v --transfers 16 --fast-list --progress --copy-links $BACKUP_LOCATION $ONEDRIVE_LOCATION
#/usr/sbin/rclone sync -v /mnt/user/CommunityApplicationsAppdataBackup/ onedrive:unraid/backup
