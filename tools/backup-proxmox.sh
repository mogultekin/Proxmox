#!/usr/bin/env bash
set -eo pipefail

#############################################
# Terminal control
#############################################

STTY_OLD=""

disable_input() {
    if [[ "$RUN_MODE" == "sequential" ]] && [[ -t 0 ]]; then
        STTY_OLD=$(stty -g)
        stty -echo -icanon min 0 time 0
    fi
}

enable_input() {
    if [[ -n "${STTY_OLD:-}" ]] && [[ -t 0 ]]; then
        stty "$STTY_OLD" 2>/dev/null || true
    fi
}

#############################################
# Cleanup handler
#############################################

cleanup() {
    enable_input
    [[ -n "${SPIN_PID:-}" ]] && kill "$SPIN_PID" 2>/dev/null || true
    echo
    echo "Backup interrupted."
    exit 1
}

trap cleanup INT TERM
trap enable_input EXIT

#############################################
# Dependency checks
#############################################

for cmd in whiptail stdbuf qm pct vzdump pvesm stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing command: $cmd"
        echo "Install with: apt install -y $cmd"
        exit 1
    fi
done

#############################################
# Progress bar
#############################################

draw_progress() {
    local id=$1 pct=$2 speed=$3
    local width=16
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    bar=$(printf "%${filled}s" | tr ' ' '█')
    space=$(printf "%${empty}s" | tr ' ' '░')
    printf "\r%-6s %s%s %3d%%  %s" "$id" "$bar" "$space" "$pct" "$speed"
}

#############################################
# Spinner
#############################################

spinner() {
    local id=$1 spin='-\|/' i=0
    while true; do
        printf "\r%-6s %c backing up..." "$id" "${spin:i++%4:1}"
        sleep 0.2
    done
}

#############################################
# Retention cleanup (protect <2h backups)
#############################################

cleanup_old_backups() {

    local ID=$1
    local TYPE=$2
    local prefix

    if [[ "$TYPE" == "VM" ]]; then
        prefix="vzdump-qemu-$ID"
    else
        prefix="vzdump-lxc-$ID"
    fi

    mapfile -t files < <(ls -t "$BACKUP_PATH"/$prefix* 2>/dev/null || true)

    newest="${files[0]}"

    for f in "${files[@]:1}"; do

        [[ ! -f "$f" ]] && continue

        mtime=$(stat -c %Y "$f")
        now=$(date +%s)
        age=$((now - mtime))

        # protect backups newer than 2 hours
        if (( age < 7200 )); then
            continue
        fi

        base=$(basename "$f")
        base=${base%%.vma.zst*}
        base=${base%%.tar.zst*}

        rm -f "$BACKUP_PATH/$base"* 2>/dev/null || true

        echo "Removed $base"

    done
}

#############################################
# Confirm start
#############################################

whiptail --title "Proxmox Backup Tool" \
--yesno "Start backup utility?" 10 60 || exit 0

#############################################
# Execution mode
#############################################

RUN_MODE=$(whiptail \
--title "Execution Mode" \
--menu "Choose execution mode" \
15 60 2 \
sequential "Run backups one-by-one" \
parallel "Run backups concurrently" \
3>&1 1>&2 2>&3) || exit 0

#############################################
# Storage selector
#############################################

STORAGES=()

while read -r NAME TYPE STATUS TOTAL USED AVAIL PCT; do
    [[ "$NAME" == "Name" ]] && continue
    [[ "$STATUS" != "active" ]] && continue
    STORAGES+=("$NAME" "$TYPE ($PCT used)")
done < <(pvesm status --content backup)

BACKUP_STORAGE=$(whiptail \
--title "Backup Storage" \
--menu "Select storage for backups" \
20 70 10 \
"${STORAGES[@]}" \
3>&1 1>&2 2>&3) || exit 0

BACKUP_PATH="/mnt/pve/${BACKUP_STORAGE}/dump"

#############################################
# Backup mode
#############################################

MODE=$(whiptail \
--title "Backup Mode" \
--menu "Select backup type" \
15 50 3 \
snapshot "Live snapshot backup" \
suspend "Suspend guest during backup" \
stop "Stop guest during backup" \
3>&1 1>&2 2>&3) || exit 0

#############################################
# Skip stopped guests
#############################################

SKIP_STOPPED=false

if whiptail \
--title "Skip stopped guests" \
--yesno "Skip guests that are not running?" \
10 60; then
    SKIP_STOPPED=true
fi

#############################################
# Build guest list
#############################################

OPTIONS=()

mapfile -t VM_LINES < <(bash --noprofile --norc -c "qm list" | awk 'NR>1')

for line in "${VM_LINES[@]}"; do

    VMID=$(awk '{print $1}' <<< "$line")
    NAME=$(awk '{print $2}' <<< "$line")
    STATUS=$(awk '{print $3}' <<< "$line")

    $SKIP_STOPPED && [[ "$STATUS" != "running" ]] && continue

    OPTIONS+=("$VMID" "VM  $STATUS  $NAME" OFF)

done

mapfile -t CT_LINES < <(bash --noprofile --norc -c "pct list" | awk 'NR>1')

for line in "${CT_LINES[@]}"; do

    CTID=$(awk '{print $1}' <<< "$line")
    STATUS=$(awk '{print $2}' <<< "$line")
    NAME=$(awk '{print $3}' <<< "$line")

    $SKIP_STOPPED && [[ "$STATUS" != "running" ]] && continue

    OPTIONS+=("$CTID" "CT  $STATUS  $NAME" OFF)

done

#############################################
# Skip selection
#############################################

SKIP=$(whiptail \
--title "Guests on $(hostname)" \
--checklist "Select guests to SKIP from backup" \
22 70 15 \
"${OPTIONS[@]}" \
3>&1 1>&2 2>&3) || exit 0

SKIP=$(echo "$SKIP" | tr -d '"')

#############################################
# Build backup list
#############################################

IDS=()

for ((i=0;i<${#OPTIONS[@]};i+=3)); do
    id="${OPTIONS[i]}"
    [[ ! " $SKIP " =~ " $id " ]] && IDS+=("$id")
done

#############################################
# Backup worker
#############################################

run_backup() {

    local ID=$1 TYPE NAME

    if qm config "$ID" &>/dev/null; then
        TYPE="VM"
        NAME=$(qm config "$ID" | awk -F': ' '/^name:/ {print $2}')
    else
        TYPE="CT"
        NAME=$(pct config "$ID" | awk -F': ' '/^hostname:/ {print $2}')
    fi

    echo
    echo "Starting $MODE backup of $TYPE:$ID-$NAME"

    disable_input

    spinner "$ID" &
    SPIN_PID=$!

    TMPLOG=$(mktemp)

    stdbuf -oL -eL vzdump "$ID" \
        --mode "$MODE" \
        --storage "$BACKUP_STORAGE" \
        --compress zstd \
        --remove 0 \
        --notes-template "$ID-$NAME@$(hostname)-$MODE" \
        > "$TMPLOG" 2>&1 &

    BACKUP_PID=$!

    while kill -0 $BACKUP_PID 2>/dev/null; do

        if grep -q "%" "$TMPLOG"; then

            line=$(grep "%" "$TMPLOG" | tail -1)

            pct=$(echo "$line" | grep -o '[0-9]\+%' | tr -d '%')

            speed=$(echo "$line" | sed -n 's/.*read: \([0-9.]\+ [A-Za-z\/]\+\).*/\1/p')

            kill $SPIN_PID 2>/dev/null || true

            draw_progress "$ID" "$pct" "$speed"

        fi

        sleep 0.5

    done

    wait $BACKUP_PID

    kill $SPIN_PID 2>/dev/null || true

    printf "\r%-6s ████████████████ 100%% done\033[K\n" "$ID"

    enable_input

    echo "Backup complete: $ID"

    cleanup_old_backups "$ID" "$TYPE"

    rm -f "$TMPLOG"
}

#############################################
# Execution
#############################################

echo
echo "Storage: $BACKUP_STORAGE"
echo "Mode: $MODE"
echo "Execution: $RUN_MODE"
echo

if [[ "$RUN_MODE" == "sequential" ]]; then

    for id in "${IDS[@]}"; do
        run_backup "$id"
    done

else

    running=0
    MAX_PARALLEL=3

    for id in "${IDS[@]}"; do

        run_backup "$id" &
        ((running++))

        if [[ "$running" -ge "$MAX_PARALLEL" ]]; then
            wait -n
            ((running--))
        fi

    done

    wait

fi

echo
echo "All backups completed."
