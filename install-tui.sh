#!/bin/bash
set -e

# Gentoo TUI Installer Wrapper (for oddlama backend)
# This script provides a beginner-friendly, interactive TUI for Gentoo installation.
# It collects user input, writes a config, and calls the main oddlama installer.
# It does NOT modify the core oddlama scripts.

# --- BEGIN CONFIGURABLES ---
MOUNT_POINT="/mnt/gentoo"
TEMP_CONFIG="/tmp/gentoo-tui.conf"
DEFAULT_HOSTNAME="gentoo"
DEFAULT_TIMEZONE="Europe/London"
DEFAULT_USERNAME="gentoo"
DEFAULT_FULLNAME="Gentoo User"
DEFAULT_SHELL="/bin/bash"
# --- END CONFIGURABLES ---

# --- Helper: Check for dialog/whiptail ---
if command -v whiptail >/dev/null 2>&1; then
    DIALOG=whiptail
elif command -v dialog >/dev/null 2>&1; then
    DIALOG=dialog
else
    echo "This installer requires 'whiptail' or 'dialog'. Please install one and re-run." >&2
    exit 1
fi

# --- Helper: Root check ---
if [[ $EUID -ne 0 ]]; then
    $DIALOG --msgbox "This script must be run as root (use sudo)" 10 60
    exit 1
fi

# --- Helper: Clean up temp config on exit ---
trap 'rm -f "$TEMP_CONFIG"' EXIT

# --- Helper: Dialog wrappers ---
msgbox() { $DIALOG --title "$1" --msgbox "$2" 14 70; }
inputbox() { $DIALOG --title "$1" --inputbox "$2" 10 70 "$3" 3>&1 1>&2 2>&3; }
passwordbox() { $DIALOG --title "$1" --passwordbox "$2" 10 70 3>&1 1>&2 2>&3; }
yesno() { $DIALOG --title "$1" --yesno "$2" 12 70; }
menu() { $DIALOG --title "$1" --menu "$2" 20 70 10 "$@" 3>&1 1>&2 2>&3; }
helpbox() { $DIALOG --title "Help" --msgbox "$1" 20 70; }

# --- Helper: Validate username ---
validate_username() {
    local username="$1"
    if [[ -z "$username" ]]; then
        return 1
    fi
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        return 1
    fi
    if [[ "$username" == "root" || "$username" == "bin" || "$username" == "daemon" ]]; then
        return 1
    fi
    return 0
}

# --- Helper: Validate password strength ---
validate_password() {
    local password="$1"
    if [[ ${#password} -lt 8 ]]; then
        return 1
    fi
    return 0
}

# --- Step 1: Welcome ---
msgbox "Gentoo TUI Installer" "Welcome to the Gentoo Linux TUI Installer!\n\nThis wizard will guide you through a safe, step-by-step installation.\n\nYou will be asked about partitions, user accounts, and system settings.\n\nPress OK to begin."

# --- Step 2: Partition Selection ---
msgbox "Partitioning" "You must manually partition your disk before running this installer.\n\nThis step will help you select which partitions to use for root, boot, and swap.\n\nWARNING: All data on selected partitions will be erased!"

# List partitions for selection
parts=()
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    fstype=$(echo "$line" | awk '{print $3}')
    mountpoint=$(echo "$line" | awk '{print $4}')
    desc="$size $fstype"
    if [[ -n "$mountpoint" ]]; then desc+=" (mounted at $mountpoint)"; fi
    parts+=("/dev/$name" "$desc")
done < <(lsblk -ln -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -E "(sd[a-z][0-9]+|nvme[0-9]+n[0-9]+p[0-9]+|hd[a-z][0-9]+|vd[a-z][0-9]+)")

if [[ ${#parts[@]} -eq 0 ]]; then
    msgbox "Error" "No partitions found. Please create partitions manually before running this installer."
    exit 1
fi

ROOT_PARTITION=$(menu "Root Partition" "Select the root (/) partition:" "${parts[@]}")
if [[ -z "$ROOT_PARTITION" ]]; then msgbox "Error" "No root partition selected."; exit 1; fi

BOOT_PARTITION=$(menu "Boot Partition" "Select the boot/EFI partition:" "${parts[@]}")
if [[ -z "$BOOT_PARTITION" ]]; then msgbox "Error" "No boot partition selected."; exit 1; fi

if yesno "Swap Partition" "Do you want to use a swap partition?"; then
    SWAP_PARTITION=$(menu "Swap Partition" "Select the swap partition:" "${parts[@]}")
    if [[ -z "$SWAP_PARTITION" ]]; then msgbox "Error" "No swap partition selected."; exit 1; fi
    USE_SWAP="yes"
else
    SWAP_PARTITION=""
    USE_SWAP="no"
fi

# --- Step 3: Account Creation ---
if yesno "User Account" "Do you want to create a user account for daily use?\n\nThis is recommended for security.\n\nYou can skip this and create users manually later."; then
    CREATE_USER="yes"
else
    CREATE_USER="no"
    USERNAME=""
    USERPASS=""
    FULLNAME=""
    SHELL_CHOICE="bash"
    ADDITIONAL_GROUPS="wheel"
fi

if [[ "$CREATE_USER" == "yes" ]]; then

# Username input with validation
while true; do
    USERNAME=$(inputbox "Username" "Enter a username for your main user (lowercase letters, numbers, underscore, hyphen):" "$DEFAULT_USERNAME")
    if [[ -z "$USERNAME" ]]; then 
        msgbox "Error" "No username entered."; exit 1
    fi
    if validate_username "$USERNAME"; then
        break
    else
        msgbox "Error" "Invalid username. Username must:\n- Start with a letter or underscore\n- Contain only lowercase letters, numbers, underscore, hyphen\n- Not be 'root', 'bin', or 'daemon'"
    fi
done

# Full name input
FULLNAME=$(inputbox "Full Name" "Enter the full name for $USERNAME:" "$DEFAULT_FULLNAME")
if [[ -z "$FULLNAME" ]]; then FULLNAME="$USERNAME"; fi

# Shell selection
SHELL_CHOICE=$(menu "Shell" "Choose default shell for $USERNAME:" "bash" "Bash (recommended)" "zsh" "Zsh (advanced)" "fish" "Fish (user-friendly)" "sh" "Sh (minimal)")
if [[ -z "$SHELL_CHOICE" ]]; then SHELL_CHOICE="bash"; fi

# Additional groups
GROUP_OPTIONS=(
    "wheel" "Sudo access (recommended)"
    "video" "Graphics drivers"
    "audio" "Sound devices"
    "netdev" "Network configuration"
    "usb" "USB devices"
    "cdrom" "CD/DVD drives"
    "floppy" "Floppy drives"
    "games" "Games"
    "input" "Input devices"
    "kvm" "Virtual machines"
    "render" "Hardware acceleration"
    "systemd-journal" "System logs (systemd only)"
)

selected_groups=()
for ((i=0; i<${#GROUP_OPTIONS[@]}; i+=2)); do
    group_name="${GROUP_OPTIONS[i]}"
    group_desc="${GROUP_OPTIONS[i+1]}"
    if yesno "Group: $group_name" "Add $USERNAME to group '$group_name'?\n\n$group_desc"; then
        selected_groups+=("$group_name")
    fi
done

# Always include wheel for sudo access
if [[ ! " ${selected_groups[@]} " =~ " wheel " ]]; then
    selected_groups+=("wheel")
fi

ADDITIONAL_GROUPS=$(IFS=','; echo "${selected_groups[*]}")

# Password input with validation
while true; do
    USERPASS=$(passwordbox "User Password" "Enter password for $USERNAME (minimum 8 characters):")
    if [[ -z "$USERPASS" ]]; then 
        msgbox "Error" "No user password entered."; exit 1
    fi
    if validate_password "$USERPASS"; then
        break
    else
        msgbox "Error" "Password too weak. Password must be at least 8 characters long."
    fi
done

# Confirm password
while true; do
    USERPASS_CONFIRM=$(passwordbox "Confirm Password" "Confirm password for $USERNAME:")
    if [[ "$USERPASS" == "$USERPASS_CONFIRM" ]]; then
        break
    else
        msgbox "Error" "Passwords do not match. Please try again."
    fi
done

# Root password
while true; do
    ROOTPASS=$(passwordbox "Root Password" "Enter password for root (minimum 8 characters):")
    if [[ -z "$ROOTPASS" ]]; then 
        msgbox "Error" "No root password entered."; exit 1
    fi
    if validate_password "$ROOTPASS"; then
        break
    else
        msgbox "Error" "Password too weak. Password must be at least 8 characters long."
    fi
done

# Confirm root password
while true; do
    ROOTPASS_CONFIRM=$(passwordbox "Confirm Root Password" "Confirm password for root:")
    if [[ "$ROOTPASS" == "$ROOTPASS_CONFIRM" ]]; then
        break
    else
        msgbox "Error" "Passwords do not match. Please try again."
    fi
done
fi

# --- Step 4: Hostname and Timezone ---
HOSTNAME=$(inputbox "Hostname" "Enter hostname for your system:" "$DEFAULT_HOSTNAME")
if [[ -z "$HOSTNAME" ]]; then msgbox "Error" "No hostname entered."; exit 1; fi
TIMEZONE=$(inputbox "Timezone" "Enter timezone (e.g. Europe/London):" "$DEFAULT_TIMEZONE")
if [[ -z "$TIMEZONE" ]]; then msgbox "Error" "No timezone entered."; exit 1; fi

# --- Step 5: Init System ---
INITSYS=$(menu "Init System" "Choose init system:" "systemd" "Modern (systemd)" "openrc" "Traditional (OpenRC)")
if [[ -z "$INITSYS" ]]; then msgbox "Error" "No init system selected."; exit 1; fi

# --- Step 6: Kernel Type ---
KERNEL_TYPE=$(menu "Kernel" "Choose kernel type:" "prebuilt" "Prebuilt (recommended)" "manual" "Manual (advanced)")
if [[ -z "$KERNEL_TYPE" ]]; then msgbox "Error" "No kernel type selected."; exit 1; fi

# --- Step 7: Show Summary ---
if [[ "$CREATE_USER" == "yes" ]]; then
    user_summary="User Account:\n- Username: $USERNAME\n- Full Name: $FULLNAME\n- Shell: $SHELL_CHOICE\n- Groups: $ADDITIONAL_GROUPS"
else
    user_summary="User Account: None (will create manually later)"
fi

summary="You are about to install Gentoo with the following settings:\n\nRoot: $ROOT_PARTITION\nBoot: $BOOT_PARTITION\nSwap: $SWAP_PARTITION\n\n$user_summary\n\nSystem:\n- Hostname: $HOSTNAME\n- Timezone: $TIMEZONE\n- Init: $INITSYS\n- Kernel: $KERNEL_TYPE\n\nALL DATA ON SELECTED PARTITIONS WILL BE ERASED!\n\nContinue?"
if ! yesno "Summary" "$summary"; then msgbox "Aborted" "Installation aborted by user."; exit 0; fi

# --- Step 8: Write Config ---
cat > "$TEMP_CONFIG" <<EOF
# Generated by install-tui.sh
GENTOO_ARCH="amd64"
STAGE3_VARIANT="$INITSYS"
PARTITIONING_SCHEME="existing_partitions"
PARTITIONING_DEVICE="$(echo $ROOT_PARTITION | sed 's/[0-9]*$//')"
PARTITIONING_BOOT_DEVICE="$BOOT_PARTITION"
PARTITIONING_ROOT_DEVICE="$ROOT_PARTITION"
PARTITIONING_SWAP_DEVICE="$SWAP_PARTITION"
PARTITIONING_USE_SWAP="$USE_SWAP"
PARTITIONING_BOOT_TYPE="$(if [[ -d /sys/firmware/efi ]]; then echo efi; else echo bios; fi)"
PARTITIONING_ROOT_FS="ext4"
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
USERNAME="$USERNAME"
USERPASS="$USERPASS"
ROOTPASS="$ROOTPASS"
FULLNAME="$FULLNAME"
SHELL_CHOICE="$SHELL_CHOICE"
ADDITIONAL_GROUPS="$ADDITIONAL_GROUPS"
CREATE_USER="$CREATE_USER"
KERNEL_TYPE="$KERNEL_TYPE"
I_HAVE_READ_AND_EDITED_THE_CONFIG_PROPERLY="true"
EOF

# --- Step 9: Call Main Installer ---
msgbox "Starting Install" "The installer will now begin. This may take a while.\n\nYou can monitor progress in another terminal."
./install -c "$TEMP_CONFIG"

# --- Step 10: Done ---
msgbox "Done" "Gentoo installation is complete!\n\nYou can now reboot into your new system.\n\nThank you for using the Gentoo TUI Installer." 