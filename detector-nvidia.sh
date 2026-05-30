#!/bin/bash

LOG_FILE="/var/log/nvidia_autoinstall.log"
ATTEMPT_FILE="/var/local/nvidia_attempted.flag"
SUCCESS_FILE="/var/local/nvidia_success.flag"


doLog() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}


run_nvidia_installation() {

    doLog "Starting NVIDIA automatic installation and enablement..."
    plymouth message --text="Installing NVIDIA Driver..." 2>/dev/null

    # 1. Configuration for full automation without blocking
    # Don't ask visual questions, choose the default option for everything
    export DEBIAN_FRONTEND=noninteractive

    # When the installer reaches the license, it sees that it has already been accepted and does not freeze the script.
    echo "nvidia-support nvidia-support/accepted-eula boolean true" | debconf-set-selections

    # 2. Ensure critical dependencies are met for the driver to compile and function
    apt-get update -y -qq

    # Removed the xserver wildcard to avoid syntax errors in APT
    apt-get install -y -qq linux-headers-$(uname -r) build-essential dkms >> "$LOG_FILE" 2>&1

    # 3. Unattended installation of the recommended driver
    # We run in the background processing the output pipeline
    while read -r line; do
        local package
        package=$(echo "$line" | awk '{print $2}' | cut -d':' -f1 | tr -d '()[]:,')
        
        if [ -n "$package" ]; then
            echo "Procesando: $package"
            plymouth message --text="Installing : $package" 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') - APT: $package" >> "$LOG_FILE"
        fi
    # Using 2>&1 redirects errors so they are also processed or logged
    # Scan your computer's buses, detect the exact model of your NVIDIA card, and search the repositories for the most stable and certified proprietary driver for it.
    done < <(LC_ALL=C stdbuf -oL ubuntu-drivers autoinstall 2>&1 | tee -a "$LOG_FILE" | grep --line-buffered -E '^Setting up|^Unpacking|^Error')

    # CORRECTION: Exact screenshot of the exit code for 'ubuntu-drivers' (the first command in the pipeline)
    local main_status=${PIPESTATUS[0]}

    # 4. IMMEDIATE ACTIVATION (The key step)
    if [ "$main_status" -eq 0 ]; then

        doLog "Installation complete. Enabling drivers in the kernel..."
        
        # Generar el mapa de dependencias de módulos de Linux
        depmod -a >> "$LOG_FILE" 2>&1
        
        # Disable the generic 'nouveau' driver to free up the GPU (if it's loaded)
        if lsmod | grep -q "nouveau"; then
            doLog "Removing the old Nouveau driver..."
            modprobe -r nouveau 2>/dev/null || echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
        fi
        
        # Force load the new NVIDIA modules into memory
        doLog "Loading official NVIDIA modules..."
        modprobe nvidia 2>>"$LOG_FILE"
        modprobe nvidia-modeset 2>>"$LOG_FILE"
        modprobe nvidia-drm 2>>"$LOG_FILE"
        
        # Update initramfs to ensure it persists on the next boot
        update-initramfs -u -k all >> "$LOG_FILE" 2>&1
        
        # Check if the card responds (Successful enablement test)
        if command -v nvidia-smi >/dev/null 2>&1; then
            doLog "SUCCESS! The NVIDIA drivers are installed and active."
            plymouth message --text="NVIDIA enabled successfully" 2>/dev/null
        else
            doLog "NOTICE: Driver installed but requires restart to take control of the graphical environment."
        fi
    else
        doLog "ERROR: Automatic installation of ubuntu-drivers failed (Code: $main_status)"
    fi

    return "$main_status"
}






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

        # 5. PREVIOUS ATTEMPT CHECK
        PREVIOUS_FAILED=0
        if [ -f "$ATTEMPT_FILE" ]; then
            doLog "WARNING: Previous attempt was interrupted. Flag detected."
            PREVIOUS_FAILED=1
        fi

        # 6. WAIT FOR THE NETWORK TO BE AVAILABLE
        doLog "Waiting for network stability..."
        plymouth message --text="Waiting for network stability..." 2>/dev/null
        # 30 seconds waiting
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


            # 11. DRIVERS INSTALL
            # We call the external function and capture its return value with $?
            run_nvidia_installation
            INSTALL_STATUS=$?

            # 12. Check for success or failure
            if [ $INSTALL_STATUS -eq 0 ]; then

                plymouth message --text="Activating Nvidia graphics profile..." 2>/dev/null
                doLog "Installation successful. Forcing Nvidia profile via prime-select..."
                
                # Forces the system to use the Nvidia GPU permanently
                if command -v prime-select &> /dev/null; then
                    prime-select nvidia >> "$LOG_FILE" 2>&1
                    doLog "prime-select: Nvidia profile enabled successfully."
                else
                    doLog "WARNING: prime-select command not found. Skipping profile activation."
                fi

                plymouth message --text="Installation completed successfully. Restarting..." 2>/dev/null
                doLog "Restarting the computer to apply changes..."    

                # If there are Nvidia graphics installed, it is considered checked by creating the SUCCESS_FILE       
                mkdir -p "$(dirname "$SUCCESS_FILE")"
                touch "$SUCCESS_FILE"

                # We remove the flag that indicates that the installation is in progress; it should only remain if the installation fails.
                rm -f "$ATTEMPT_FILE"

                # >>> THE SUBTLE SECURITY IMPROVEMENT <<<
                # Force the hard drive to save files created and deleted before restarting
                sync

                sleep 3
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
            if [ $PREVIOUS_FAILED -eq 1 ] ; then exit 1; fi
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
rm -f "$ATTEMPT_FILE"

doLog "=== Check completed successfully ==="