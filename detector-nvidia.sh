#!/bin/bash


# LOG_FILE is the file where all the logs of the process are stored, it is useful to check what happened in case of failure.
# ATTEMPT_FILE is a flag file that indicates that an installation attempt has been made. 
# It is created at the beginning of the installation process and deleted at the end if everything went well. 
# If it exists at the beginning of the process, it means that a previous attempt was made but did not complete successfully,
# so the script will try to repair the package system in the next reboot before attempting the installation again.
# SUCCESS_FILE is a flag file that indicates that the installation was successful.
# It is created at the end of the process if everything went well giving the chance not to store and forcing a hardware check again in the next reboot.
# It is somewhat redundant to be requesting the deletion or not of the SUCCESS_FILE but a delay of 5 seconds
# does not mean anything when booting in the case that you do not want to delete it
LOG_FILE="/var/log/nvidia_autoinstall.log"
ATTEMPT_FILE="/var/local/nvidia_attempted.flag"
SUCCESS_FILE="/var/local/nvidia_success.flag"

# Initial value different than y or n to know if the question is already done to to be done again
removeSuccessFlag='0'

# Function to display a question about whether to delete the file, indicating success of the operation
# A global script variable is used that is updated inside the function and used within the script outside the function
removeSuccessFlagQuestion() {

    # 1. Display the message on the Plymouth screen
    plymouth message --text="Do you want to remove the success flag ? (y/n): " 2>/dev/null
    
    # 2. Capture the key within a 5-second limit
    local key_pressed
    key_pressed=$(timeout --signal=INT 5 plymouth watch-keystroke --keys="yYnN" 2>/dev/null)
    
    # 3. Clear the message from the screen so it doesn't get stuck.
    plymouth message --text="" 2>/dev/null
    
    # 4. We evaluate the result
    if [ -z "$key_pressed" ]; then
        # If time has expired, you can decide whether to leave it at '0', 'n' or whatever you prefer
        removeSuccessFlag='n'
    else
        # If a key was pressed, we convert it to lowercase
        removeSuccessFlag=$(echo "$key_pressed" | tr '[:upper:]' '[:lower:]')
    fi
}


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
        sleep 2
        
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
            sleep 2
        fi
        
        # Force load NVIDIA modules into live memory
        doLog "Loading official NVIDIA modules..."
        plymouth message --text="Loading official NVIDIA modules..." 2>/dev/null
        modprobe nvidia 2>>"$LOG_FILE"
        modprobe nvidia-modeset 2>>"$LOG_FILE"
        modprobe nvidia-drm modeset=1 2>>"$LOG_FILE"
        sleep 2
        
        # Update initramfs to persist modules on next boot
        doLog "Updating initramfs..."
        plymouth message --text="Updating initramfs..." 2>/dev/null
        update-initramfs -u -k all >/dev/null 2>&1
        sleep 2

    else
        plymouth message --text="ERROR: Automatic installation via ubuntu-drivers failed (Exit code: $main_status)" 2>/dev/null
        doLog "ERROR: Automatic installation via ubuntu-drivers failed (Exit code: $main_status)"
        sleep 2
    fi

    return "$main_status"
}





# Start the script...

# 1. VALIDATE ROOT PRIVILEGES
if [ "$EUID" -ne 0 ]; then
    doLog "The nvidia-detector script must be run as root (sudo)." >&2
    plymouth message --text="The nvidia-detector script must be run as root (sudo)." 2>/dev/null
    sleep 2
    exit 1
fi

doLog "=== Starting startup check ==="
plymouth message --text="=== Starting startup check ===" 2>/dev/null
sleep 2

# 2. AVOID EXECUTION IF IT HAS ALREADY SUCCESSFUL IN THE PAST
# You will need to manually remove /var/local/nvidia_success.flag to bypass this check
# Or answer affirmatively to the question asked
# If the $SUCCESS_FILE exists the program gives the user the chance to check the hardware if he knows it has changed or to avoid and to avoid it ignoring the question not lose time
# Also the script gives the chance to delete the SUCCESS_FILE for the mandatorily next check on the next reboot
# In next steps the script gives also the same chance once the $SUCCESS_FILE is created.
if [ -f "$SUCCESS_FILE" ]; then

    doLog "Driver status: Already successfully installed by this script previously."
    plymouth message --text="Driver status: Already successfully installed by this script previously." 2>/dev/null
    sleep 2

    # 1. Display the question on the screen. Systemd will wait a maximum of 5 seconds
    # If the user does not type anything correctly, the variable will remain empty
    plymouth message --text="Do you want to force graphics card detection again ? (y/n): " 2>/dev/null
    theAnswer=$(timeout --signal=INT 5 plymouth watch-keystroke --keys="yYnN" 2>/dev/null)
    theAnswer=$(echo "$theAnswer" | tr '[:upper:]' '[:lower:]')

    # 2. Evaluate what the user did
    if [ "$theAnswer" == "y" ]; then
        doLog "[INFO] Starting forced graph detection..."
        plymouth message --text="[INFO] Starting forced graph detection..." 2>/dev/null
        # If you want to force the detection of the graphics card immediately, it will necessarily generate the SUCCESS_FILE file
        removeSuccessFlag='n'
        sleep 2
    else
        # If you type "no", anything else, or the 15 seconds are up :
        doLog "[INFO] Timeout expired or negative response. Continuing with normal startup..."
        plymouth message --text="[INFO] Timeout expired or negative response. Continuing with normal startup..." 2>/dev/null
        sleep 2

        # Only if the success file exists and the question has not been done previously
        if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "0" ]]; then
            removeSuccessFlagQuestion
        fi

        # If the user wishes to delete the file that indicates the success of the operation, if one exists
        if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "y" ]]; then
            rm -f "$SUCCESS_FILE"
        fi 

        exit 0
    fi
fi


# 3. VALIDATE NVIDIA HARDWARE
if lspci | grep -qi nvidia; then

    doLog "Hardware detected: Nvidia card present."
    plymouth message --text="Hardware detected: Nvidia card present." 2>/dev/null
    sleep 2

    
    # 4. CHECK IF THE DRIVERS ARE ALREADY INSTALLED
    if ! command -v nvidia-smi &> /dev/null; then

        doLog "Driver status: NOT installed."
        plymouth message --text="Driver status: NOT installed." 2>/dev/null
        sleep 2

        
        PREVIOUS_FAILED=0
        # 5. PREVIOUS ATTEMPT CHECK
        if [ -f "$ATTEMPT_FILE" ]; then
            doLog "WARNING: Previous attempt was interrupted. Flag detected."
            plymouth message --text="WARNING: Previous attempt was interrupted. Flag detected." 2>/dev/null
            sleep 2
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
            sleep 2

            # 8. LOCKOUT CONTROL WITH TIMEOUT (Maximum 2 minutes)
            block_attempts=0
            max_block_attempts=24

            # wait safely for the package installation system (APT) to be released in Linux.
            while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
                if [ $block_attempts -ge $max_block_attempts ]; then
                    doLog "ERROR: The package manager is still blocked after 2 minutes. Aborting installation."
                    plymouth message --text="Package system busy. Skipping installation." 2>/dev/null
                    if [ ! -f "$ATTEMPT_FILE" ]; then
                        touch "$ATTEMPT_FILE"
                    fi
                    sleep 2
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
                sleep 2

                dpkg --configure -a >> "$LOG_FILE" 2>&1
                apt-get install -f -y >> "$LOG_FILE" 2>&1
                apt-get clean >> "$LOG_FILE" 2>&1

                # EFFECTIVE VERIFICATION
                if apt-get check >> "$LOG_FILE" 2>&1; then
                    PREVIOUS_FAILED=0
                    doLog "Repair completed successfully. Package system is healthy."
                    plymouth message --text="Repair completed successfully. Package system is healthy." 2>/dev/null
                    sleep 2
                else
                    doLog "CRITICAL ERROR: Package system is still broken after repair attempts. Aborting installation."
                    plymouth message --text="System repair failed. Skipping installation for safety." 2>/dev/null
                    if [ ! -f "$ATTEMPT_FILE" ]; then
                        touch "$ATTEMPT_FILE"
                    fi
                    sleep 2
                    exit 1
                fi
            fi


            # 10. >>> REAL FLAG OF DANGEROUS OPERATION <<<
            if [ ! -f "$ATTEMPT_FILE" ]; then
                touch "$ATTEMPT_FILE"
            fi
            doLog "Installation flag active. Starting repository update..."

            apt-get update >> "$LOG_FILE" 2>&1

            plymouth message --text="Looking for the best certified controller..." 2>/dev/null
            doLog "Repositories updated. Preparing installer..."
            sleep 2


            # 11. DRIVERS INSTALL
            # We call the external function and capture its return value with $?
            run_nvidia_installation
            INSTALL_STATUS=$?

            # 12. Check for success or failure
            if [ $INSTALL_STATUS -eq 0 ]; then

                plymouth message --text="Activating Nvidia graphics profile..." 2>/dev/null
                doLog "Installation successful. Forcing Nvidia profile via prime-select..."
                sleep 2
                
                # Forces the system to use the Nvidia GPU permanently
                if command -v prime-select &> /dev/null; then
                    prime-select nvidia >> "$LOG_FILE" 2>&1
                    doLog "prime-select: Nvidia profile enabled successfully."
                    plymouth message --text="prime-select: Nvidia profile enabled successfully." 2>/dev/null
                    sleep 2
                else
                    doLog "WARNING: prime-select command not found. Skipping profile activation."
                    plymouth message --text="WARNING: prime-select command not found. Skipping profile activation." 2>/dev/null
                    sleep 2
                fi

                plymouth message --text="Installation completed successfully. Restarting..." 2>/dev/null
                doLog "Restarting the computer to apply changes..."    

                # If there are Nvidia graphics installed, it is considered checked by creating the SUCCESS_FILE
                mkdir -p "$(dirname "$SUCCESS_FILE")"
                if [ ! -f "$SUCCESS_FILE" ]; then
                    touch "$SUCCESS_FILE"
                fi
                

                # We remove the flag that indicates that the installation is in progress; it should only remain if the installation fails.
                if [ -f "$ATTEMPT_FILE" ]; then
                   rm -f "$ATTEMPT_FILE"
                fi

                sleep 2

                # Only if the success file exists and the question has not been answered previously
                if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "0" ]]; then
                    removeSuccessFlagQuestion
                fi

                if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "y" ]]; then
                    rm -f "$SUCCESS_FILE"
                fi 

                reboot
            else
                plymouth message --text="Critical error during installation. Continuing boot..." 2>/dev/null
                doLog "ERROR: The process ended with exit code $INSTALL_STATUS."
                if [ ! -f "$ATTEMPT_FILE" ]; then
                    touch "$ATTEMPT_FILE"
                fi
                sleep 2
                exit 1
            fi
        else
            # We need to install drivers but we don't have internet access
            doLog "Internet connection: ERROR. Network unavailable after waiting."
            plymouth message --text="No internet connection. Skipping installation." 2>/dev/null
            sleep 2

            # Only if the success file exists and the question has not been answered previously
            if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "0" ]]; then
                removeSuccessFlagQuestion
            fi 

            # If we are coming from a previous failure, we do not delete the flag
            if [ $PREVIOUS_FAILED -eq 1 ]; then 
                if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "y" ]]; then
                    rm -f "$SUCCESS_FILE"
                fi
                exit 1
            fi
        fi
    else
        # If there are Nvidia graphics installed, it is considered checked by creating the SUCCESS_FILE
        mkdir -p "$(dirname "$SUCCESS_FILE")"
        if [ ! -f "$SUCCESS_FILE" ]; then
            touch "$SUCCESS_FILE"
        fi

        doLog "Driver status: Already installed and working."
        plymouth message --text="Driver status: Already installed and working." 2>/dev/null
        sleep 2

        # Only if the success file exists and the question has not been answered previously
        if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "0" ]]; then
            removeSuccessFlagQuestion
        fi
    fi
else
    # If there is no Nvidia graphics card, it is considered checked by creating the SUCCESS_FILE
    # Check that the drivers are not installed; if they are, uninstall them.
    doLog "Hardware detected: No Nvidia card."
    plymouth message --text="Hardware detected: No Nvidia card." 2>/dev/null
    sleep 2

    # Let's assume that there are no drivers installed or that they are successfully removed
    mkdir -p "$(dirname "$SUCCESS_FILE")"
    if [ ! -f "$SUCCESS_FILE" ]; then
        touch "$SUCCESS_FILE"
    fi

    # Only if the success file exists and the question has not been answered previously
    if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "0" ]]; then
        removeSuccessFlagQuestion
    fi

    if command -v nvidia-smi &> /dev/null; then

        # The Nvidia drivers are installed
        doLog "Nvidia drivers installed. We will now uninstall them."
        plymouth message --text="Removing unused NVIDIA drivers..." 2>/dev/null
        sleep 2

        # Force non-interactive mode to avoid APT prompt crashes
        export DEBIAN_FRONTEND=noninteractive

        # Complete uninstallation and purging of packages and dependencies
        apt-get clean -y -qq 2>>"$LOG_FILE"
        apt-get update --fix-missing -y -qq 2>>"$LOG_FILE"
	    dpkg --configure -a 2>>"$LOG_FILE"
	    apt-get install -f -y -qq 2>>"$LOG_FILE"
        apt-get remove -y -qq '^nvidia-.*' '^libnvidia-.*' xserver-xorg-video-nvidia*  2>>"$LOG_FILE"
        apt-get autoremove --purge -y -qq 2>>"$LOG_FILE"
        apt-get install xserver-xorg-video-nouveau -y -qq 2>>"$LOG_FILE"

        # Cleaning up Nvidia X11 video settings
        rm -f /etc/X11/xorg.conf
        rm -f /etc/X11/xorg.conf.d/*nvidia*

        # Restore the open-source driver (Nouveau) if it was locked
        if [ -f "/etc/modprobe.d/blacklist-nouveau.conf" ]; then
            doLog "Restoring open-source Nouveau driver configuration..."
            plymouth message --text="Restoring open-source Nouveau driver configuration..." 2>/dev/null
            rm -f /etc/modprobe.d/blacklist-nouveau.conf
            update-initramfs -u -k all >/dev/null 2>&1
            sleep 2
        fi

        # Checking if the uninstallation was successful or not
        if ! command -v nvidia-smi &> /dev/null && ! dpkg -l | grep -qE "^ii.*nvidia-(driver|kernel)"; then
            doLog "SUCCESS: Unused NVIDIA drivers have been completely removed."
            plymouth message --text="Unused NVIDIA drivers removed." 2>/dev/null
        else
            doLog "WARNING: APT commands finished but some NVIDIA packages or configurations still remain."
            plymouth message --text="WARNING: Partial NVIDIA driver removal." 2>/dev/null

            # Activating recovery mode for the next reboot
            mkdir -p "$(dirname "$ATTEMPT_FILE")"
            if [ ! -f "$ATTEMPT_FILE" ]; then
                touch "$ATTEMPT_FILE"
            fi

            # We will delete the file that indicates it was successful because that is not the case
            if [ -f "$SUCCESS_FILE" ]; then
                rm -f "$SUCCESS_FILE"
            fi

            exit 1
        fi
    else
        doLog "System is clean. No Nvidia drivers detected."
        plymouth message --text="System is clean. No Nvidia drivers detected." 2>/dev/null
    fi
    sleep 2
fi

# It's removed just in case; it only arrives here if everything has gone well.
if [ -f "$ATTEMPT_FILE" ]; then
    rm -f "$ATTEMPT_FILE"
fi

# If the user wishes to delete the file that indicates the success of the operation, if one exists
if [[ -f "$SUCCESS_FILE" && "$removeSuccessFlag" == "y" ]]; then
    rm -f "$SUCCESS_FILE"
fi 

doLog "=== Check completed successfully ==="
plymouth message --text="=== Check completed successfully ===" 2>/dev/null
sleep 2
