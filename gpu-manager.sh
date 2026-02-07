#!/bin/bash

# ==============================================================================
# Arch Linux GPU Passthrough Manager
# ==============================================================================

VFIO_CONF="/etc/modprobe.d/vfio.conf"
LOADER_DIR="/boot/loader/entries"
MKINIT_CONF="/etc/mkinitcpio.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Store start time
START_TIME_UNIX="$(date +%s)"

# 1. Root Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root.${NC}"
  exit 1
fi

# 2. File Existence Check
if [ ! -f "$MKINIT_CONF" ]; then
    echo -e "${RED}Error: $MKINIT_CONF not found! Aborting.${NC}"
    exit 1
fi

# ==============================================================================
# Function: Hardware Detection
# ==============================================================================
print_gpu_status() {
    if [ -f "$VFIO_CONF" ]; then
        ACTIVE_IDS=$(grep "ids=" "$VFIO_CONF" | cut -d "=" -f 2)
    else
        ACTIVE_IDS=""
    fi

    count=0
    GPU_IDS=()
    AUDIO_IDS=()
    GPU_NAMES=()
    CURRENT_STATE=()

    # Query lspci ONCE
    local lspci_data=$(lspci -nnk)

    echo -e "\n${YELLOW}GPU Status Table:${NC}"
    echo "--------------------------------------------------------------------------------"

    # Process each GPU found
    while read -r line; do
        bus_id=$(echo "$line" | cut -d " " -f 1)
        pci_id=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)
        name=$(echo "$line" | cut -d ":" -f 3- | sed 's/ (rev.*//')

        # We look for the block starting with our bus_id.
        # We stop immediately if we see a line starting with a digit (next device)
        # OR an empty line. This prevents "bleeding" into other devices.
        current_driver=$(echo "$lspci_data" | awk -v bus="$bus_id" '
            $0 ~ "^"bus {p=1; next}
            p && /^[0-9a-f]/ {exit}
            p && /Kernel driver in use:/ {print $5; exit}
        ' | xargs)

        [ -z "$current_driver" ] && current_driver="None"

        # Find Audio ID associated with this bus (function .1)
        base_bus=${bus_id%.*}
        audio_id=$(echo "$lspci_data" | grep "$base_bus" | grep -i "Audio" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)

        GPU_IDS[$count]=$pci_id
        AUDIO_IDS[$count]=$audio_id
        GPU_NAMES[$count]=$name

        if [[ "$ACTIVE_IDS" == *"$pci_id"* ]]; then
            CURRENT_STATE[$count]=1
            state_str="${RED}[PASSTHROUGH]${NC}"
        else
            CURRENT_STATE[$count]=0
            state_str="${GREEN}[HOST]${NC}"
        fi

        driver_color="${NC}"
        if [[ "$current_driver" == "vfio-pci" ]]; then
            driver_color="${RED}"
        elif [[ "$current_driver" == "amdgpu" || "$current_driver" == "nvidia" ]]; then
            driver_color="${GREEN}"
        fi

        echo -e "$((count+1)). $state_str $name"
        echo -e "    ID: $pci_id | Audio ID: $audio_id"
        echo -e "    Driver in use: ${driver_color}${current_driver}${NC}"
        echo "--------------------------------------------------------------------------------"
        ((count++))
    done < <(echo "$lspci_data" | grep -E "VGA|3D")
    GLOBAL_COUNT=$count
}

# ==============================================================================
# Function: Repair mkinitcpio.conf MODULES (Hardened)
# ==============================================================================
fix_mkinitcpio_modules() {
    echo "3. Verifying $MKINIT_CONF MODULES order..."

    # Create Backup
    cp "$MKINIT_CONF" "${MKINIT_CONF}.bak.$START_TIME_UNIX"

    # Robust extraction: remove assignments and delimiters
    raw_content=$(grep "^MODULES=" "$MKINIT_CONF" | sed -E 's/^MODULES=[("'\'' ]*//; s/[)"'\'' ]*$//')
    read -ra current_modules <<< "$raw_content"

    # SAFETY CHECK: If array is empty, something is wrong with the grep. Abort.
    if [ ${#current_modules[@]} -eq 0 ]; then
        # Check if the file actually has a MODULES line that might be empty
        if ! grep -q "^MODULES=" "$MKINIT_CONF"; then
             echo -e "${RED}CRITICAL ERROR: Could not parse MODULES in $MKINIT_CONF.${NC}"
             echo "Restoring backup..."
             mv "${MKINIT_CONF}.bak" "$MKINIT_CONF"
             exit 1
        fi
        # If it's just empty "MODULES=()", that's technically allowed, proceed carefully
    fi

    vfio_req=("vfio_pci" "vfio" "vfio_iommu_type1")
    new_modules=()

    for m in "${current_modules[@]}"; do
        skip=false
        # Remove existing VFIO/GPU entries to re-order them
        for req in "${vfio_req[@]}"; do [[ "$m" == "$req" ]] && skip=true; done
        [[ "$m" == "amdgpu" || "$m" == "nvidia" || "$m" == "nouveau" ]] && skip=true
        if [ "$skip" = false ]; then new_modules+=("$m"); fi
    done

    final_modules=("${vfio_req[@]}" "${new_modules[@]}" "amdgpu" "nvidia")

    # Write changes
    sed -i "s/^MODULES=.*/MODULES=(${final_modules[*]})/" "$MKINIT_CONF"
    echo -e "   ${GREEN}[OK]${NC} MODULES=( ${final_modules[*]} )"
}

# ==============================================================================
# Start Script Logic
# ==============================================================================
echo ""
echo -e "${BLUE}=== Arch Linux GPU Passthrough Manager ===${NC}"

# 1. Initial Status Print
print_gpu_status

# 2. User Input
echo -e "\n${YELLOW}Commands:${NC} (pass: +X, host: -X)"
echo -n "> "
read -r cmd_input
if [ -z "$cmd_input" ]; then echo "No changes requested. Exiting."; exit 0; fi

# 3. Select Target Bootloader Entry
echo -e "\n${YELLOW}Select Target Bootloader Entry:${NC}"
shopt -s nullglob
entries=("$LOADER_DIR"/*.conf)
if [ ${#entries[@]} -eq 0 ]; then echo -e "${RED}No bootloader entries found!${NC}"; exit 1; fi

ENTRY_FILES=()
DEFAULT_IDX=1
CURRENT_KERNEL_TYPE=$(uname -r)

for i in "${!entries[@]}"; do
    idx=$((i+1))
    ENTRY_FILES[$idx]=${entries[$i]}
    filename=$(basename "${entries[$i]}")
    is_current=""
    entry_content=$(grep "^linux" "${entries[$i]}")
    if [[ "$CURRENT_KERNEL_TYPE" == *"zen"* ]] && [[ "$entry_content" == *"zen"* ]]; then
        is_current=" ${GREEN}(Current)${NC}"; DEFAULT_IDX=$idx
    elif [[ "$CURRENT_KERNEL_TYPE" != *"zen"* ]] && [[ "$entry_content" != *"zen"* ]]; then
        is_current=" ${GREEN}(Current)${NC}"; DEFAULT_IDX=$idx
    fi
    echo -e "$idx. $filename$is_current"
done

echo -n "> [$DEFAULT_IDX]: "
read -r entry_choice
entry_choice=${entry_choice:-$DEFAULT_IDX}
TARGET_ENTRY_FILE=${ENTRY_FILES[$entry_choice]}

if [ -z "$TARGET_ENTRY_FILE" ]; then echo -e "${RED}Invalid selection.${NC}"; exit 1; fi

# 4. Logic Processing
declare -a NEW_STATE
for ((i=0; i<GLOBAL_COUNT; i++)); do NEW_STATE[$i]=${CURRENT_STATE[$i]}; done

for token in $cmd_input; do
    action=${token:0:1}
    id=${token:1}

    # STRICT INPUT VALIDATION: Ensure ID is actually a number
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        idx=$((id-1))
        if [[ $idx -ge 0 && $idx -lt $GLOBAL_COUNT ]]; then
            [ "$action" == "+" ] && NEW_STATE[$idx]=1
            [ "$action" == "-" ] && NEW_STATE[$idx]=0
        else
            echo -e "${YELLOW}Warning: GPU ID $id out of range, ignoring.${NC}"
        fi
    else
        echo -e "${YELLOW}Warning: Invalid input '$token', ignoring.${NC}"
    fi
done

NEW_ID_LIST=""
for ((i=0; i<GLOBAL_COUNT; i++)); do
    if [ "${NEW_STATE[$i]}" -eq 1 ]; then
        [ -z "$NEW_ID_LIST" ] && NEW_ID_LIST="${GPU_IDS[$i]}" || NEW_ID_LIST="$NEW_ID_LIST,${GPU_IDS[$i]}"
        [ ! -z "${AUDIO_IDS[$i]}" ] && NEW_ID_LIST="$NEW_ID_LIST,${AUDIO_IDS[$i]}"
    fi
done

# ==============================================================================
# 5. Commit Changes
# ==============================================================================
echo -e "\n${YELLOW}Applying Configuration Changes...${NC}"

# A. Update vfio.conf
echo "1. Writing $VFIO_CONF"

# Create Backup
cp "$VFIO_CONF" "$VFIO_CONF.bak.$START_TIME_UNIX"

cat <<EOF > "$VFIO_CONF"
# Auto-generated by gpu-manager.sh
options vfio-pci ids=$NEW_ID_LIST
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
EOF

# B. Bootloader Management
echo "2. Updating Bootloader entries..."
for entry in "${ENTRY_FILES[@]}"; do
    # Create Backup
    cp "$entry" "${entry}.bak.$START_TIME_UNIX"

    if [ "$entry" == "$TARGET_ENTRY_FILE" ]; then
        echo -e "   ${GREEN}[TARGET]${NC} Enabling IOMMU for $entry)"

        # Ensure IOMMU is on, remove blacklist, remove empty ID override
        sed -i 's/modprobe.blacklist=vfio_pci//g' "$entry"
        sed -i 's/vfio_pci.ids=//g' "$entry" # Clean the empty ID override if it exists
        if ! grep -q "amd_iommu=on" "$entry"; then sed -i '/^options/ s/$/ amd_iommu=on/' "$entry"; fi
        if ! grep -q "iommu=pt" "$entry"; then sed -i '/^options/ s/$/ iommu=pt/' "$entry"; fi
    else
        echo -e "   ${CYAN}[RESCUE]${NC} Blacklisting VFIO from $entry"

        # Remove IOMMU, Add Blacklist, force empty vfio ids
        sed -i 's/amd_iommu=on//g' "$entry"
        sed -i 's/iommu=pt//g' "$entry"
        if ! grep -q "vfio_pci.ids=" "$entry"; then sed -i '/^options/ s/$/ vfio_pci.ids=/' "$entry"; fi
        if ! grep -q "modprobe.blacklist=vfio_pci" "$entry"; then sed -i '/^options/ s/$/ modprobe.blacklist=vfio_pci/' "$entry"; fi
    fi
    sed -i -E 's/vfio-pci.ids=[^ ]*//g' "$entry"
    sed -i 's/  */ /g' "$entry"; sed -i 's/[[:space:]]*$//' "$entry"
done

# C. mkinitcpio logic
fix_mkinitcpio_modules

# D. Rebuild
echo -e "4. Regenerating initramfs images... ${RED}(Please wait)${NC}"
mkinitcpio -P

# 6. Final UI
print_gpu_status
echo -e "\n${GREEN}Done! System is now configured.${NC}"
echo -e "Target Boot Entry: ${CYAN}$(basename "$TARGET_ENTRY_FILE")${NC}"
echo "Please reboot."

