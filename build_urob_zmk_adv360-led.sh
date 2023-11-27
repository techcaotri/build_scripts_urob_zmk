#!/bin/bash

# ----------------------------------
# Colors
# ----------------------------------
NOCOLOR='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHTGRAY='\033[0;37m'
DARKGRAY='\033[1;30m'
LIGHTRED='\033[1;31m'
LIGHTGREEN='\033[1;32m'
YELLOW='\033[1;33m'
LIGHTBLUE='\033[1;34m'
LIGHTPURPLE='\033[1;35m'
LIGHTCYAN='\033[1;36m'
WHITE='\033[1;37m'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SOURCE_DIR="$SCRIPT_DIR/../source_urob_zmk_adv360-led" 
CONFIG_DIR="$SCRIPT_DIR/../from-urob-zmk-config"
ZMK_DIR="$SOURCE_DIR/zmk"

init_build_environment() {
	echo -e "${LIGHTBLUE}Initialize the Adv360 Pro 'adv360-led' build environment...${NOCOLOR}"
	source ../.venv/bin/activate
	cp -i "$CONFIG_DIR/config/west.yml.adv360-led" "$CONFIG_DIR/config/west.yml"

	echo -e "${LIGHTBLUE}Initialize application to CONFIG_DIR's 'config' dir...${NOCOLOR}"
	cd "$SOURCE_DIR" || exit
	west init -l config

	echo -e "${LIGHTBLUE}Update to Fetch Modules ...${NOCOLOR}"
	west update
	echo -e "${LIGHTBLUE}Export Zephyr CMake package...${NOCOLOR}"
	west zephyr-export
	echo -e "${LIGHTBLUE}Install Zephyr Python Dependencies...${NOCOLOR}"
	pip install -r zephyr/scripts/requirements.txt
}

compile_firmware() {
  force_flag=""
  if [ $1 = true ]; then
    force_flag="--force"
  fi
  echo "force_flag: $force_flag"
  output_dir="$SCRIPT_DIR/adv360-led_output_uf2"
  mkdir -p "$output_dir"
	 $CONFIG_DIR/scripts/zmk_build.sh -l -o "$output_dir" \
    --host-config-dir "$CONFIG_DIR" \
    --host-zmk-dir "$ZMK_DIR" -- $force_flag
}

usage() {
    echo "Usage: $0 [-h|--help] [-i|--init] [-f|--force]"
    echo
    echo "Argmuments:"
    echo "  -h, --help    Display this help message"
    echo "  -i, --init    Init the build environment"
    echo "  -f, --force   Force rebuild"
    echo "The default (no argument) will compile the firmware"
    exit 1
}

force=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            ;;
        -u | --update)
            init_build_environment
            ;;
        -f | --force)
            force=true
            ;;
        *)
            usage
            ;;
    esac
    shift
done

compile_firmware $force
