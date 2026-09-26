#!/bin/bash

# Color definitions for a terminal formatting
BOLD='\033[1m'
RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

# Automatic privilege elevation
if [ "$EUID" -ne 0 ]; then
  if [ -f "$0" ] && [ "$0" != "bash" ]; then
    exec sudo "$0" "$@"
  else
    echo "Privileges required. Re-running with sudo..."
    exec sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/EcthorSilva/steamos-automount/main/script.sh)" -- "$@"
  fi
fi

clear
echo -e "${CYAN}${BOLD}======================================================${RESET}"
echo -e "${CYAN}${BOLD}     SteamOS Secondary Drive Automount Setup          ${RESET}"
echo -e "${CYAN}${BOLD}======================================================${RESET}\n"

# Identify the drive where SteamOS is installed
OS_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null)
[ -z "$OS_DISK" ] && OS_DISK="nvme0n1"

echo -e "${BLUE}Protected System Drive:${RESET} ${BOLD}/dev/$OS_DISK${RESET}"
echo -e "${BLUE}Searching for available secondary devices...${RESET}\n"

# Ignoring system drive, zram, and loop
ALL_DEVS=$(lsblk -P -o NAME,TYPE,PKNAME,FSTYPE,SIZE,UUID | grep -v "$OS_DISK" | grep -v "zram" | grep -v "loop")

# Identify disks with existing partitions
PART_PARENTS=$(echo "$ALL_DEVS" | grep 'TYPE="part"' | sed -n 's/.*PKNAME="\([^"]*\)".*/\1/p' | sort -u)

mapfile -t BLOCKS < <(
  echo "$ALL_DEVS" | while read -r line; do
    eval "$line"
    if [ "$TYPE" = "part" ]; then
      echo "NAME=\"$NAME\" FSTYPE=\"$FSTYPE\" SIZE=\"$SIZE\" UUID=\"$UUID\" TYPE=\"$TYPE\""
    elif [ "$TYPE" = "disk" ]; then
      if ! echo "$PART_PARENTS" | grep -q -w "$NAME"; then
        echo "NAME=\"$NAME\" FSTYPE=\"$FSTYPE\" SIZE=\"$SIZE\" UUID=\"$UUID\" TYPE=\"$TYPE\""
      fi
    fi
  done
)

if [ ${#BLOCKS[@]} -eq 0 ]; then
    echo -e "${RED}[X] No secondary drives or partitions found.${RESET}"
    exit 1
fi

echo -e "${BOLD}Available Devices:${RESET}\n"

index=1
declare -A DEV_NAME DEV_FSTYPE DEV_SIZE DEV_UUID

for block in "${BLOCKS[@]}"; do
    eval "$block"
    DEV_NAME[$index]="$NAME"
    DEV_FSTYPE[$index]="${FSTYPE:-n/a}"
    DEV_SIZE[$index]="$SIZE"
    DEV_UUID[$index]="${UUID:-n/a}"

    DEV_STR=$(printf "%-8s" "/dev/$NAME")
    SIZE_STR=$(printf "%-8s" "${SIZE:-N/A}")
    
    if [ "${FSTYPE:-n/a}" != "ext4" ]; then
        FMT_RAW="Format to ext4"
        FMT_STR=$(printf "%-15s" "$FMT_RAW")
        FMT_COL="${YELLOW}${FMT_STR}${RESET}"
    else
        FMT_RAW="ext4"
        FMT_STR=$(printf "%-15s" "$FMT_RAW")
        FMT_COL="${GREEN}${FMT_STR}${RESET}"
    fi

    echo -e "  ${BOLD}[$index]${RESET} ${CYAN}${DEV_STR}${RESET}  ${BOLD}|${RESET}  Size: ${BOLD}${SIZE_STR}${RESET}  ${BOLD}|${RESET}  Format: $FMT_COL"
    ((index++))
done

echo ""
read -p "$(echo -e "${BOLD}Select device number to configure (1-$((index-1))): ${RESET}")" CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -ge "$index" ]; then
    echo -e "\n${RED}[X] Invalid choice! Operation canceled.${RESET}"
    exit 1
fi

SELECTED_DEV="${DEV_NAME[$CHOICE]}"
SELECTED_FSTYPE="${DEV_FSTYPE[$CHOICE]}"
SELECTED_SIZE="${DEV_SIZE[$CHOICE]}"
SELECTED_UUID="${DEV_UUID[$CHOICE]}"
TARGET_DEV="/dev/$SELECTED_DEV"

# UUID check
if [ -n "$SELECTED_UUID" ] && [ "$SELECTED_UUID" != "n/a" ]; then
    OLD_SERVICE=$(grep -l "$SELECTED_UUID" /etc/systemd/system/var-mnt-*.mount 2>/dev/null)

    if [ -n "$OLD_SERVICE" ]; then
        OLD_SERVICE_NAME=$(basename "$OLD_SERVICE")
        OLD_MOUNT_POINT=$(grep "Where=" "$OLD_SERVICE" | cut -d'=' -f2)

        echo -e "\n${YELLOW}${BOLD}[!] THIS DEVICE WAS PREVIOUSLY CONFIGURED!${RESET}"
        echo -e "    • Current Mount Point: ${BOLD}$OLD_MOUNT_POINT${RESET}"
        echo -e "    • Active Service:      ${BOLD}$OLD_SERVICE_NAME${RESET}\n"
        
        read -p "$(echo -e "${BOLD}Do you want to remove the previous config and reconfigure? [y/N]: ${RESET}")" RECONFIG

        if [[ "$RECONFIG" =~ ^[Yy]$ ]]; then
            echo -e "\n${BLUE}--> Removing old mount service...${RESET}"
            systemctl disable --now "$OLD_SERVICE_NAME" 2>/dev/null
            rm -f "$OLD_SERVICE"
            systemctl daemon-reload

            if [ -d "$OLD_MOUNT_POINT" ]; then
                rmdir "$OLD_MOUNT_POINT" 2>/dev/null
            fi
            echo -e "${GREEN}[+] Old configuration successfully removed!${RESET}\n"
        else
            echo -e "${YELLOW}Operation canceled by user.${RESET}"
            exit 0
        fi
    fi
fi

# summary
echo -e "\n${CYAN}------------------------------------------------------${RESET}"
echo -e " ${BOLD}Selection Summary:${RESET}"
echo -e "   • Device: ${BOLD}$TARGET_DEV${RESET}"
echo -e "   • Size:   ${BOLD}${SELECTED_SIZE:-N/A}${RESET}"
echo -e "   • Format: ${BOLD}$SELECTED_FSTYPE${RESET}"
echo -e "   • UUID:   ${BOLD}$SELECTED_UUID${RESET}"
echo -e "${CYAN}------------------------------------------------------${RESET}\n"

# Formatting and systemd mount setup
if [ "$SELECTED_FSTYPE" != "ext4" ]; then
    echo -e "${YELLOW}${BOLD}[!] WARNING: Device is not formatted as EXT4.${RESET}"
    echo -e "    Steam requires native ext4 filesystem on Linux.\n"
    read -p "$(echo -e "${BOLD}Do you want to format $TARGET_DEV to EXT4 now? [y/N]: ${RESET}")" CONFIRM_FORMAT

    if [[ "$CONFIRM_FORMAT" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}--> Unmounting and partitioning $TARGET_DEV...${RESET}"
        umount -l "$TARGET_DEV" 2>/dev/null

        IS_DISK=$(lsblk -no TYPE "$TARGET_DEV" 2>/dev/null | head -n1)
        if [ "$IS_DISK" = "disk" ]; then
            parted -s "$TARGET_DEV" mklabel gpt
            parted -s "$TARGET_DEV" mkpart primary ext4 0% 100%
            partprobe "$TARGET_DEV"
            sleep 2
            
            if [[ "$TARGET_DEV" =~ nvme ]]; then
                TARGET_DEV="${TARGET_DEV}p1"
            else
                TARGET_DEV="${TARGET_DEV}1"
            fi
        fi

        echo -e "${BLUE}--> Formatting to EXT4...${RESET}"
        mkfs.ext4 -F "$TARGET_DEV" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}[X] Failed to format device.${RESET}"
            exit 1
        fi
        echo -e "${GREEN}[+] Formatting completed successfully!${RESET}\n"
    else
        echo -e "${RED}[X] Operation canceled. EXT4 format is mandatory.${RESET}"
        exit 1
    fi
fi

SELECTED_UUID=$(blkid -s UUID -o value "$TARGET_DEV")

read -p "$(echo -e "${BOLD}Enter a name for the mount point (e.g. ssd1tb, games_hd): ${RESET}")" MOUNT_NAME
CLEAN_NAME=$(echo "$MOUNT_NAME" | sed 's/[^a-zA-Z0-9_-]//g')

if [ -z "$CLEAN_NAME" ]; then
    echo -e "${RED}[X] Invalid name! Operation canceled.${RESET}"
    exit 1
fi

MOUNT_DIR="/var/mnt/$CLEAN_NAME"
SERVICE_NAME="var-mnt-${CLEAN_NAME}.mount"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

echo -e "\n${BLUE}--> Creating mount service at ${BOLD}$MOUNT_DIR${RESET}..."
mkdir -p "$MOUNT_DIR"

cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Automount Drive $CLEAN_NAME

[Mount]
What=/dev/disk/by-uuid/$SELECTED_UUID
Where=$MOUNT_DIR
Type=ext4
Options=defaults,nofail

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1

mkdir -p "$MOUNT_DIR/steamapps"
chown -R deck:deck "$MOUNT_DIR"
chmod -R 775 "$MOUNT_DIR"

echo -e "${GREEN}[+] Systemd mount unit enabled and active on boot!${RESET}"

# Automatic injection steam library
echo -e "\n${BLUE}--> Linking drive to Steam Library...${RESET}"
pkill -u deck -x steam 2>/dev/null
sleep 1

python3 - "$MOUNT_DIR" << 'EOF'
import sys, os, re

target_path = sys.argv[1]
vdf_paths = [
    "/home/deck/.local/share/Steam/config/libraryfolders.vdf",
    "/home/deck/.steam/steam/config/libraryfolders.vdf",
    "/home/deck/.steam/root/config/libraryfolders.vdf"
]

vdf_file = None
for p in vdf_paths:
    if os.path.exists(p):
        vdf_file = p
        break

if not vdf_file:
    print("  [!] libraryfolders.vdf not found.")
    sys.exit(0)

with open(vdf_file, 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()

if target_path in content:
    print("  \033[0;32m[+] Drive path is already linked in Steam!\033[0m")
    sys.exit(0)

indices = [int(i) for i in re.findall(r'"(\d+)"\s*\{', content)]
next_idx = str(max(indices) + 1 if indices else 1)

new_entry = f'''\t"{next_idx}"
\t{{
\t\t"path"\t\t"{target_path}"
\t\t"label"\t\t""
\t\t"mounted"\t\t"1"
\t}}'''

last_brace = content.rfind('}')
if last_brace != -1:
    new_content = content[:last_brace] + new_entry + '\n' + content[last_brace:]
    with open(vdf_file, 'w', encoding='utf-8') as f:
        f.write(new_content)
    print(f"  \033[0;32m[+] Drive successfully added to Steam Library!\033[0m")
EOF

chown deck:deck /home/deck/.local/share/Steam/config/libraryfolders.vdf 2>/dev/null
chown deck:deck /home/deck/.steam/steam/config/libraryfolders.vdf 2>/dev/null

# File manager shortcut (Dolphin)
echo ""
read -p "$(echo -e "${BOLD}Add shortcut to File Manager (Dolphin)? [Y/n]: ${RESET}")" ADD_SHORTCUT

if [[ ! "$ADD_SHORTCUT" =~ ^[Nn]$ ]]; then
    SUDO_USER_HOME=$(eval echo "~${SUDO_USER:-deck}")
    USER_PLACES="$SUDO_USER_HOME/.local/share/user-places.xbel"

    if [ -f "$USER_PLACES" ]; then
        python3 - "$MOUNT_DIR" "$CLEAN_NAME" "$USER_PLACES" << 'EOF'
import sys, xml.etree.ElementTree as ET

mount_dir, clean_name, places_file = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    tree = ET.parse(places_file)
    root = tree.getroot()
    
    for elem in list(root.findall('bookmark')):
        if elem.get('href') == f'file://{mount_dir}':
            root.remove(elem)

    bookmark = ET.Element('bookmark', {'href': f'file://{mount_dir}'})
    
    title = ET.SubElement(bookmark, 'title')
    title.text = f"{clean_name}"
    
    info = ET.SubElement(bookmark, 'info')
    metadata = ET.SubElement(info, 'metadata', {'owner': 'http://www.kde.org'})
    
    icon_elem = ET.SubElement(metadata, 'icon', {'name': 'drive-harddisk-solid'})
    
    root.append(bookmark)
    tree.write(places_file, encoding='utf-8', xml_declaration=True)
    print("  \033[0;32m[+] Shortcut successfully added to Dolphin Places!\033[0m")
except Exception as e:
    pass
EOF
        chown "${SUDO_USER:-deck}:${SUDO_USER:-deck}" "$USER_PLACES" 2>/dev/null
    fi
fi

echo -e "\n${GREEN}${BOLD}======================================================${RESET}"
echo -e "${GREEN}${BOLD}   [+] DRIVE CONFIGURED & READY FOR STEAM GAMES!      ${RESET}"
echo -e "${GREEN}${BOLD}======================================================${RESET}\n"
echo -e "   • Device: ${BOLD}$TARGET_DEV${RESET}"
echo -e "   • Mount:  ${BOLD}$MOUNT_DIR${RESET}\n"