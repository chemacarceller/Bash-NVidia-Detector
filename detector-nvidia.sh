#!/bin/bash

LOG_FILE="/var/log/nvidia_autoinstall.log"
ATTEMPT_FILE="/var/local/nvidia_attempted.flag"

# 1. VALIDATE ROOT PRIVILEGES
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

doLogin() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

doLogin "=== Starting startup check ==="

# 2. VALIDATE NVIDIA HARDWARE
if lspci | grep -qi nvidia; then
    doLogin "Hardware detected: Nvidia card present."

    # 3. CHECK IF THE DRIVERS ARE ALREADY INSTALLED
    if ! command -v nvidia-smi &> /dev/null; then
        doLogin "Driver status: NOT installed."

        # 4. PREVIOUS ATTEMPT CHECK
        PREVIOUS_FAILED=0
        if [ -f "$ATTEMPT_FILE" ]; then
            doLogin "WARNING: Previous attempt was interrupted. Flag detected."
            PREVIOUS_FAILED=1
        fi

        # 5. WAIT FOR THE NETWORK TO BE AVAILABLE
        doLogin "Waiting for network stability..."
        plymouth message --text="Waiting for network stability..." 2>/dev/null
        for i in {1..15}; do
            if [ "$(nmcli networking connectivity)" = "full" ]; then
                break
            fi
            sleep 2
        done

        # 6. CHECK FINAL INTERNET CONNECTION
        if [ "$(nmcli networking connectivity)" = "full" ]; then
            doLogin "Internet connection: OK."

            plymouth message --text="Connecting to Ubuntu repositories..." 2>/dev/null

            # LOCKOUT CONTROL WITH TIMEOUT (Maximum 2 minutes)
            block_attempts=0
            max_block_attempts=24

            while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
                if [ $block_attempts -ge $max_block_attempts ]; then
                    doLogin "ERROR: The package manager is still blocked after 2 minutes. Aborting installation."
                    plymouth message --text="Package system busy. Skipping installation." 2>/dev/null
                    exit 1
                fi

                doLogin "Packet manager busy. Waiting 5 seconds... (Attempt $((block_attempts+1))/$max_block_attempts)"
                plymouth message --text="Packet manager busy. Waiting 5 seconds..." 2>/dev/null
                sleep 5
                ((block_attempts++))
            done


            # >>> RESCUE PROTOCOL <<<
            if [ $PREVIOUS_FAILED -eq 1 ]; then
                plymouth message --text="Repairing package system..." 2>/dev/null
                doLogin "Starting package system repair..."

                dpkg --configure -a >> "$LOG_FILE" 2>&1
                apt-get install -f -y >> "$LOG_FILE" 2>&1
                apt-get clean >> "$LOG_FILE" 2>&1

                # EFFECTIVE VERIFICATION
                if apt-get check >> "$LOG_FILE" 2>&1; then
                    PREVIOUS_FAILED=0
                    doLogin "Repair completed successfully. Package system is healthy."
                    plymouth message --text="Repair completed successfully. Package system is healthy." 2>/dev/null
                else
                    doLogin "CRITICAL ERROR: Package system is still broken after repair attempts. Aborting installation."
                    plymouth message --text="System repair failed. Skipping installation for safety." 2>/dev/null
                    exit 1
                fi
            fi


            # >>> REAL FLAG OF DANGEROUS OPERATION <<<
            touch "$ATTEMPT_FILE"
            doLogin "Installation flag active. Starting repository update..."

            apt-get update >> "$LOG_FILE" 2>&1

            plymouth message --text="Looking for the best certified controller..." 2>/dev/null
            doLogin "Repositories updated. Preparing installer..."


            # 7. INSTALLATION AND PROGRESS CAPTURE
            set -o pipefail

            DEBIAN_FRONTEND=noninteractive ubuntu-drivers install 2>&1 | tee -a "$LOG_FILE" | while read -r line; do
                if echo "$line" | grep -E -q "Inst|Configur|Desempaquetando|Unpacking"; then
                    package=$(echo "$line" | awk '{print $2}' | cut -d':' -f1)
                    if [ -n "$package" ]; then
                        plymouth message --text="Installing: $package ..." 2>/dev/null
                        doLogin "APT Progress: $package"
                    fi
                fi
            done

            INSTALL_STATUS=$?
            set +o pipefail

            # Check for success or failure
            if [ $INSTALL_STATUS -eq 0 ]; then
                plymouth message --text="Installation completed successfully. Restarting..." 2>/dev/null
                doLogin "Installation completed successfully. Restarting the computer..."
                rm -f "$ATTEMPT_FILE"
                sleep 3
                reboot
            else
                plymouth message --text="Critical error during installation. Continuing boot..." 2>/dev/null
                doLogin "ERROR: The process ended with exit code $INSTALL_STATUS."
                sleep 2
                exit 1
            fi
        else
            doLogin "Internet connection: ERROR. Network unavailable after waiting."
            plymouth message --text="No internet connection. Skipping installation." 2>/dev/null
            sleep 2
            if [ $PREVIOUS_FAILED -eq 1 ] ; then exit 1; fi
        fi
    else
        doLogin "Driver status: Already installed and working."
    fi
else
    doLogin "Hardware detected: No Nvidia card."
fi

rm -f "$ATTEMPT_FILE"

doLogin "=== Check completed successfully ==="

