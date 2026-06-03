#!/bin/bash

# Files to store logs and to indicate that the operating system is ready and should not perform the process, or that the operating system has problems and needs to be fixed.
LOG_FILE="/var/log/nvidia_autoinstall.log"
ATTEMPT_FILE="/var/local/nvidia_attempted.flag"
SUCCESS_FILE="/var/local/nvidia_success.flag"

# Function to save logs
doLog() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to load NVidia drivers
run_nvidia_installation() {

    main_status=0

    # Force system language to English for predictable string parsing (Setting up, Unpacking...)
    export LANG=en_US.UTF-8
    export LC_ALL=C.UTF-8
    export DEBIAN_FRONTEND=noninteractive

    doLog "Starting automatic NVIDIA installation and activation..."
    plymouth message --text="Installing NVIDIA Driver..." 2>/dev/null

    # 1. Configuration for full automation without prompts
    echo "nvidia-support nvidia-support/accepted-eula boolean true" | debconf-set-selections

    # 2. Secure critical build dependencies (without conflicting generic driver wildcards)
    apt-get update -y -qq
    apt-get install -y -qq linux-headers-$(uname -r) build-essential dkms 2>/dev/null

    # 3. Unattended driver installation
    # Activate the 'lastpipe' option so that the loop runs on the main thread and PIPESTATUS works
    shopt -s lastpipe

    ubuntu-drivers install 2>&1 | while read -r aLine; do
        # Save to the log cleanly
        echo "$aLine" >> "$LOG_FILE"
    
        # Extract only keywords and clean excess text
        aMessage=$(echo "$aLine" | grep -oE "(Unpacking|Preparing|Selecting|Setting|Created|Processing|Updating|Get:).*" | head -n 1)
    
        if [ -n "$aMessage" ]; then
            # Show formatted message on loading screen
            plymouth message --text="$aMessage"
            sleep 0.5
        fi
    done

    # PIPESTATUS[0] will now correctly return the ubuntu-drivers exit code
    main_status=${PIPESTATUS[0]}

    # 4. Immediate kernel module loading
    if [ $main_status -eq 0 ]; then
    
        doLog "Installation completed. Enabling drivers in Kernel..."
        plymouth message --text="Installation completed. Enabling drivers in Kernel..." 2>/dev/null
        sleep 1
        
        # Prevent Nouveau from loading on next boot
        echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
        
        # Generate Linux module dependency maps
        depmod -a
        
        # Attempt to hot-unload Nouveau if active
        if lsmod | grep -q "nouveau"; then
            doLog "Removing legacy Nouveau driver..."
            plymouth message --text="Removing legacy Nouveau driver..." 2>/dev/null 
            echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
            modprobe -r nouveau 2>/dev/null || doLog "Warning: Nouveau in use. Changes apply after reboot."
            sleep 1
        fi
        
        # Force load NVIDIA modules into live memory
        doLog "Loading official NVIDIA modules..."
        plymouth message --text="Loading official NVIDIA modules..." 2>/dev/null
        modprobe nvidia 2>>"$LOG_FILE"
        modprobe nvidia-modeset 2>>"$LOG_FILE"
        modprobe nvidia-drm modeset=1 2>>"$LOG_FILE"
        sleep 1
        
        # Update initramfs to persist modules on next boot
        doLog "Updating initramfs..."
        plymouth message --text="Updating initramfs..." 2>/dev/null
        update-initramfs -u -k all >/dev/null 2>&1
        sleep 1

    else
        plymouth message --text="ERROR: Automatic installation via ubuntu-drivers failed (Exit code: $main_status)" 2>/dev/null
        doLog "ERROR: Automatic installation via ubuntu-drivers failed (Exit code: $main_status)"
        sleep 1
    fi

    return "$main_status"
}




# Start the script...


# 1. VALIDATE ROOT PRIVILEGES
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

doLog "=== Starting startup check ==="

# 2. AVOID EXECUTION IF IT HAS ALREADY SUCCESSFUL IN THE PAST
# You will need to manually remove /var/local/nvidia_success.flag to bypass this check
if [ -f "$SUCCESS_FILE" ]; then
    doLog "Driver status: Already successfully installed by this script previously."
    exit 0
fi

# 3. VALIDATE NVIDIA HARDWARE
if lspci | grep -qi nvidia; then

    doLog "Hardware detected: Nvidia card present."

    
    # 4. CHECK IF THE DRIVERS ARE ALREADY INSTALLED
    if ! command -v nvidia-smi &> /dev/null; then

        doLog "Driver status: NOT installed."
        
        PREVIOUS_FAILED=0
        # 5. PREVIOUS ATTEMPT CHECK
        if [ -f "$ATTEMPT_FILE" ]; then
            doLog "WARNING: Previous attempt was interrupted. Flag detected."
            PREVIOUS_FAILED=1
        fi

        # 6. WAIT FOR THE NETWORK TO BE AVAILABLE
        doLog "Waiting for network stability..."
        plymouth message --text="Waiting for network stability..." 2>/dev/null
        # 30 seconds waiting for internet connection
        for i in {1..15}; do
            if [ "$(nmcli networking connectivity)" = "full" ]; then
                break
            fi
            sleep 2
        done

        # 7. CHECK FINAL INTERNET CONNECTION
        # It is also allowed to continue if the ping works
        if [ "$(nmcli networking connectivity)" = "full" ] || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then

            doLog "Internet connection: OK."

            plymouth message --text="Connecting to Ubuntu repositories..." 2>/dev/null

            # 8. LOCKOUT CONTROL WITH TIMEOUT (Maximum 2 minutes)
            block_attempts=0
            max_block_attempts=24

            # wait safely for the package installation system (APT) to be released in Linux.
            while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
                if [ $block_attempts -ge $max_block_attempts ]; then
                    doLog "ERROR: The package manager is still blocked after 2 minutes. Aborting installation."
                    plymouth message --text="Package system busy. Skipping installation." 2>/dev/null
                    exit 1
                fi

                doLog "Packet manager busy. Waiting 5 seconds... (Attempt $((block_attempts+1))/$max_block_attempts)"
                plymouth message --text="Packet manager busy. Waiting 5 seconds..." 2>/dev/null
                sleep 5
                ((block_attempts++))
            done


            # 9. >>> RESCUE PROTOCOL <<<
            if [ $PREVIOUS_FAILED -eq 1 ]; then
                plymouth message --text="Repairing package system..." 2>/dev/null
                doLog "Starting package system repair..."

                dpkg --configure -a >> "$LOG_FILE" 2>&1
                apt-get install -f -y >> "$LOG_FILE" 2>&1
                apt-get clean >> "$LOG_FILE" 2>&1

                # EFFECTIVE VERIFICATION
                if apt-get check >> "$LOG_FILE" 2>&1; then
                    PREVIOUS_FAILED=0
                    doLog "Repair completed successfully. Package system is healthy."
                    plymouth message --text="Repair completed successfully. Package system is healthy." 2>/dev/null
                else
                    doLog "CRITICAL ERROR: Package system is still broken after repair attempts. Aborting installation."
                    plymouth message --text="System repair failed. Skipping installation for safety." 2>/dev/null
                    exit 1
                fi
            fi


            # 10. >>> REAL FLAG OF DANGEROUS OPERATION <<<
            touch "$ATTEMPT_FILE"
            doLog "Installation flag active. Starting repository update..."

            apt-get update >> "$LOG_FILE" 2>&1

            plymouth message --text="Looking for the best certified controller..." 2>/dev/null
            doLog "Repositories updated. Preparing installer..."
            sleep 1


            # 11. DRIVERS INSTALL
            # We call the external function and capture its return value with $?
            run_nvidia_installation
            INSTALL_STATUS=$?

            # 12. Check for success or failure
            if [ $INSTALL_STATUS -eq 0 ]; then

                plymouth message --text="Activating Nvidia graphics profile..." 2>/dev/null
                doLog "Installation successful. Forcing Nvidia profile via prime-select..."
                sleep 1
                
                # Forces the system to use the Nvidia GPU permanently
                if command -v prime-select &> /dev/null; then
                    prime-select nvidia >> "$LOG_FILE" 2>&1
                    doLog "prime-select: Nvidia profile enabled successfully."
                    plymouth message --text="prime-select: Nvidia profile enabled successfully." 2>/dev/null
                    sleep 1
                else
                    doLog "WARNING: prime-select command not found. Skipping profile activation."
                    plymouth message --text="WARNING: prime-select command not found. Skipping profile activation." 2>/dev/null
                    sleep 1
                fi

                plymouth message --text="Installation completed successfully. Restarting..." 2>/dev/null
                doLog "Restarting the computer to apply changes..."    

                # If there are Nvidia graphics installed, it is considered checked by creating the SUCCESS_FILE       
                mkdir -p "$(dirname "$SUCCESS_FILE")"
                touch "$SUCCESS_FILE"

                # We remove the flag that indicates that the installation is in progress; it should only remain if the installation fails.
                if [ -f "$ATTEMPT_FILE" ]; then
                   rm -f "$ATTEMPT_FILE"
                fi

                sleep 2

                reboot
            else
                plymouth message --text="Critical error during installation. Continuing boot..." 2>/dev/null
                doLog "ERROR: The process ended with exit code $INSTALL_STATUS."
                sleep 2
                exit 1
            fi
        else
            # We need to install drivers but we don't have internet access
            doLog "Internet connection: ERROR. Network unavailable after waiting."
            plymouth message --text="No internet connection. Skipping installation." 2>/dev/null
            sleep 2

            # If we are coming from a previous failure, we do not delete the flag
            if [ $PREVIOUS_FAILED -eq 1 ]; then 
                exit 1
            fi
        fi
    else
        # If there are Nvidia graphics installed, it is considered checked by creating the SUCCESS_FILE
        mkdir -p "$(dirname "$SUCCESS_FILE")"
        touch "$SUCCESS_FILE"
        doLog "Driver status: Already installed and working."
    fi
else
    # If there is no Nvidia graphics card, it is considered checked by creating the SUCCESS_FILE
    mkdir -p "$(dirname "$SUCCESS_FILE")"
    touch "$SUCCESS_FILE"
    doLog "Hardware detected: No Nvidia card."
fi

# It's removed just in case; it only arrives here if everything has gone well.
if [ -f "$ATTEMPT_FILE" ]; then
    rm -f "$ATTEMPT_FILE"
fi

doLog "=== Check completed successfully ==="
