#!/bin/bash

# Path to the Kubernetes config file (replace with your actual path)
CONFIG="/path/to/your/kubeconfig"

# Log directory for backup logs
LOG_DIR="/var/log/jenkins-backup-logs"

# Source and destination directories for rsync
SOURCE="/mnt/jenkins-home-data-pvc"  # Source path (e.g., Jenkins PVC)
DESTINATION="/data/starstore/jenkins2/JENKINS-HOME"  # Destination path (e.g., NFS mount)

# Mount point directory (e.g., where the NFS is mounted)
MOUNT_POINT="/data/starstore/jenkins2"

# Slack webhook URL for notifications (replace with your actual webhook URL)
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to send a message to Slack
send_slack_message() {
    local message="$1"
    curl -X POST -H 'Content-type: application/json' --data "{\"text\":\"$message\"}" "$SLACK_WEBHOOK_URL"
}

# Logging functions
log_info() {
    echo "$(date) [INFO]: $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo "$(date) [WARN]: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "$(date) [ERROR]: $1" | tee -a "$LOG_FILE"
}

# Function to check if the Kubernetes storage class is local-storage
is_local_storage() {
    kubectl --kubeconfig "$CONFIG" get pvc -n jenkins -o=jsonpath='{.items[*].spec.storageClassName}' | grep -q "local-storage"
}

# Function to check if the destination is an NFS mount
is_nfs_mount() {
    if mountpoint -q "$MOUNT_POINT"; then
        if grep "$MOUNT_POINT" /proc/mounts | grep -q nfs; then
            return 0  # It is an NFS mount
        else
            log_error "$MOUNT_POINT is a mount point but not an NFS mount"
            send_slack_message "$MOUNT_POINT is a mount point but not an NFS mount"
            return 1
        fi
    else
        log_error "$MOUNT_POINT is not a mount point"
        send_slack_message "$MOUNT_POINT is not a mount point"
        return 1
    fi
}

# Function to sync using rsync from source to destination with retries
run_rsync_to_destination() {
    local retries=3
    local count=0
    log_info "Starting rsync from source to destination: rsync -Pavhz --delete $SOURCE/* $DESTINATION"

    while (( count < retries )); do
        if rsync -Pavhz --delete "$SOURCE"/* "$DESTINATION"/ >> >(while read -r line; do echo "$(date +'%Y-%m-%d %H:%M:%S') $line"; done >> "$LOG_FILE" 2>&1); then
            log_info "rsync to destination completed successfully"
            return 0
        else
            log_error "rsync to destination encountered an error, attempt $((count + 1))/$retries"
            count=$((count + 1))
            sleep 60  # Wait for 60 seconds before retrying
        fi
    done

    log_error "rsync to destination failed after $retries attempts"
    send_slack_message "Jenkins Home DIR sync to NFS encountered an error after $retries attempts"
    return 1
}

# Function to sync using rsync from destination to source with retries
run_rsync_to_source() {
    local retries=3
    local count=0
    log_info "Starting rsync from destination to source: rsync -Pavhz --delete $DESTINATION/* $SOURCE"

    while (( count < retries )); do
        if rsync -Pavhz --delete "$DESTINATION"/* "$SOURCE"/ >> >(while read -r line; do echo "$(date +'%Y-%m-%d %H:%M:%S') $line"; done >> "$LOG_FILE" 2>&1); then
            log_info "rsync to source completed successfully"
            return 0
        else
            log_error "rsync to source encountered an error, attempt $((count + 1))/$retries"
            count=$((count + 1))
            sleep 60  # Wait for 60 seconds before retrying
        fi
    done

    log_error "rsync to source failed after $retries attempts"
    send_slack_message "Jenkins Home DIR sync to local encountered an error after $retries attempts"
    return 1
}

# Function to handle signals (SIGINT, SIGTERM, SIGHUP)
handle_signal() {
    local signal_name="$1"
    log_warn "Received $signal_name signal. Notifying..."

    # Get the last 10 lines of the log file for debugging
    local log_snippet
    log_snippet=$(tail -n 10 "$LOG_FILE")

    # Send the log snippet along with the message
    send_slack_message "rsync process received $signal_name signal and was interrupted. Last log lines:\n\`\`\`$log_snippet\`\`\`"
}

# Trap signals
trap 'handle_signal SIGINT' SIGINT
trap 'handle_signal SIGTERM' SIGTERM
trap 'handle_signal SIGHUP' SIGHUP

# Main loop function
main_loop() {
    while true; do
        # Update the log file name each loop iteration to reflect the current date
        LOG_FILE="$LOG_DIR/jenkins-backup-$(date +'%Y-%m-%d').log"
        
        log_info "Checking if the storage class is local-storage..."
        if is_local_storage; then
            log_info "Checking if $MOUNT_POINT is an NFS mount..."
            if is_nfs_mount; then
                log_info "Storage class is local-storage and $MOUNT_POINT is an NFS mount. Starting rsync from source to destination..."
                if run_rsync_to_destination; then
                    log_info "Sync to destination completed successfully. Waiting for next sync interval..."
                else
                    log_error "Sync to destination failed. Retrying in the next interval."
                fi
            else
                log_warn "Skipping rsync because $MOUNT_POINT is not an NFS mount."
            fi
        else
            log_info "Checking if $MOUNT_POINT is an NFS mount..."
            if is_nfs_mount; then
                log_info "Storage class is not local-storage and $MOUNT_POINT is an NFS mount. Starting rsync from destination to source..."
                if run_rsync_to_source; then
                    log_info "Sync to source completed successfully. Waiting for next sync interval..."
                else
                    log_error "Sync to source failed. Retrying in the next interval."
                fi
            else
                log_warn "Skipping rsync because $MOUNT_POINT is not an NFS mount."
            fi
        fi
        sleep 360  # Sleep for 6 minutes (360 seconds) before the next sync
    done
}

# Main execution
main_loop
