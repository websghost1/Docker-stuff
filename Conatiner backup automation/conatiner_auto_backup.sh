#!/bin/bash
set -e

# Initial configurations
BACKUP_ROOT="/path_to_container_backup"
DATE_STR=$(date +%F)
BACKUP_DIR="$BACKUP_ROOT/Backup-$DATE_STR"
CONTAINER_NAME="your_name"
IMAGE_NAME="blah_image_$DATE_STR"
BACKUP_CONTAINER_NAME="blah_backup_$DATE_STR"

mkdir -p "$BACKUP_DIR"


#save logs :
exec > >(tee -a "$BACKUP_DIR/backup.log") 2>&1



# Function to check if a client backup job is currently running inside the container via the agent
check_active_agent_backup() {
  if sudo docker exec "$CONTAINER_NAME" ps aux | grep -Ei "BackupJob|RestoreJob|InFileDelta|schedulerTask|JobController|taskExecutor" | grep -v grep > /dev/null; then
    echo "$(date): [ERROR] Active client backup detected. Aborting."
    exit 1
  fi
}

# Function to print progress with elapsed time
step_start_time=0
start_step() {
  step_start_time=$(date +%s)
  echo "=============================="
  echo "Starting: $1"
  echo "=============================="
}
end_step() {
  local step_end_time=$(date +%s)
  local duration=$((step_end_time - step_start_time))
  echo "Completed: $1 (Elapsed: ${duration}s)"
  echo ""
}

# Prevent concurrent runs of this backup script using a lockfile
LOCKFILE="/tmp/_backup.lock"
if [ -e "$LOCKFILE" ]; then
  echo "$(date): [ERROR] Backup script is already running. Exiting."
  exit 1
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

start_step "Pre-backup validation"
check_active_agent_backup
end_step "Pre-backup validation"

start_step "Stopping container $CONTAINER_NAME"
sudo docker stop "$CONTAINER_NAME"
end_step "Stopping container $CONTAINER_NAME"

start_step "Backing up volumes"
# Prepare list of directories in home_folders to backup structure only
find /mnt/nas/user/home_folders -type d > /tmp/folders_to_backup.txt

tar czvf "$BACKUP_DIR/${CONTAINER_NAME}_files_$DATE_STR.tar.gz" \
  /mnt/config /mnt/system /mnt/system/obs \
  --files-from=/tmp/folders_to_backup.txt
end_step "Backing up volumes"

start_step "Creating container image $IMAGE_NAME"
sudo docker commit "$CONTAINER_NAME" "$IMAGE_NAME"
end_step "Creating container image $IMAGE_NAME"

start_step "Saving image as tar to $BACKUP_DIR"
sudo docker save -o "$BACKUP_DIR/${IMAGE_NAME}.tar" "$IMAGE_NAME"
end_step "Saving image"

start_step "Creating backup container $BACKUP_CONTAINER_NAME"
sudo docker create --name "$BACKUP_CONTAINER_NAME" \
  -p 80:80 -p 443:443 \
  -v /mnt/config:/usr/local/cbs/conf \
  -v /mnt/system:/usr/local/cbs/system \
  -v /mnt/system/obs:/usr/local/cbs/system/obs \
  -v /mnt/nas/user/home_folders:/mnt/nas/user/home_folders \
  "$IMAGE_NAME"
end_step "Creating backup container"

start_step "Starting container $CONTAINER_NAME"
sudo docker start "$CONTAINER_NAME"
end_step "Starting container"

start_step "Cleaning up backup directories older than 7 days"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "Backup-*" -mtime +7 -exec rm -rf {} \;
end_step "Cleanup old backup directories"

echo "$(date): Backup completed successfully."
