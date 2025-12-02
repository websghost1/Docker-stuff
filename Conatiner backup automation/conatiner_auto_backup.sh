#!/bin/bash
set -e

# Initial configurations
BACKUP_ROOT="/mnt/blah_blah_container_backup"
DATE_STR=$(date +%F)
BACKUP_DIR="$BACKUP_ROOT/Backup-$DATE_STR"
CONTAINER_NAME="blah_blahcbs"
IMAGE_NAME="blah_blahcbs_image_$DATE_STR"
BACKUP_CONTAINER_NAME="blah_blah_backup_$DATE_STR"

mkdir -p "$BACKUP_DIR"

# Save logs
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

# Function to cleanup old images, leaving only 3 latest
cleanup_images() {
  echo "Cleaning up old Docker images, keeping only 3 newest..."
  docker images --format "{{.Repository}}:{{.Tag}} {{.CreatedAt}}" | grep "^blah_blahcbs_image_" | sort -r -k2 | tail -n +4 | awk '{print $1}' | xargs -r docker rmi || true
}

# Function to cleanup old backup containers, leaving only 3 newest
cleanup_containers() {
  echo "Cleaning up old backup containers, keeping only 3 newest..."
  docker ps -a --filter "name=blah_blah_backup_" --format "{{.ID}} {{.CreatedAt}}" | sort -r -k2 | tail -n +4 | awk '{print $1}' | xargs -r docker rm || true
}

# Prevent concurrent runs of this backup script using a lockfile
LOCKFILE="/tmp/blah_blah_backup.lock"
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
find /mnt/nas/user/home_folders /mnt/nvme-nas/home_folders -type d > /tmp/folders_to_backup.txt

tar czvf "$BACKUP_DIR/${CONTAINER_NAME}_files_$DATE_STR.tar.gz" \
  /mnt/blah_blah/config /mnt/blah_blah/system /mnt/blah_blah/user/ /mnt/blah_blah/system/obs \
  --files-from=/tmp/folders_to_backup.txt
end_step "Backing up volumes"

start_step "Creating container image $IMAGE_NAME"
sudo docker commit "$CONTAINER_NAME" "$IMAGE_NAME"
end_step "Creating container image $IMAGE_NAME"

start_step "Saving image as tar to $BACKUP_DIR"
sudo docker save -o "$BACKUP_DIR/${IMAGE_NAME}.tar" "$IMAGE_NAME"
end_step "Saving image"

sudo docker create --name "$BACKUP_CONTAINER_NAME" \
  -p 80:80 -p 443:443 \
  -v /mnt/blah_blah/config:/usr/local/cbs/conf \
  -v /mnt/blah_blah/system:/usr/local/cbs/system \
  -v /mnt/blah_blah/logs:/usr/local/cbs/logs \
  -v /mnt/blah_blah/user:/usr/local/cbs/user \
  -v /mnt/nvme-nas/home_folders:/mnt/nvme-nas/home_folders \
  -v /mnt/nas/user/home_folders:/mnt/nas/user/home_folders \
  "$IMAGE_NAME"


start_step "Starting container $CONTAINER_NAME"
sudo docker start "$CONTAINER_NAME"
end_step "Starting container"

start_step "Cleaning up backup directories older than 7 days"
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name "Backup-*" ! -newermt "7 days ago" -exec rm -rf {} \;
end_step "Cleanup old backup directories"

start_step "Cleaning up old Docker images and containers"
cleanup_containers
cleanup_images
end_step "Cleanup Docker images and containers"

echo "$(date): Backup completed successfully."
