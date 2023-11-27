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


info() {
	echo -e "${GREEN}$@${NOCOLOR}"
}

compile_firmware() {
  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
  info "SCRIPT_DIR: $SCRIPT_DIR"
  SOURCE_DIR=$(realpath "$1")
  info "SOURCE_DIR: $SOURCE_DIR"
  CONFIG_DIR="$1/from-urob-zmk-config"
  info "CONFIG_DIR: $CONFIG_DIR"
  ZMK_DIR="$SOURCE_DIR/zmk"
  info "ZMK_DIR: $ZMK_DIR"

	force_flag=""
	if [ $2 = true ]; then
		force_flag="-- -p"
	fi
	echo "force_flag: $force_flag"
	output_dir="$SCRIPT_DIR/sofle_output_uf2"
	mkdir -p "$output_dir"
  OPTIONS=" -l -o "$output_dir" --host-config-dir "$CONFIG_DIR" --host-zmk-dir "$ZMK_DIR" $force_flag"
  echo "$CONFIG_DIR"/scripts/zmk_build.sh "$OPTIONS"
  "$CONFIG_DIR"/scripts/zmk_build.sh $OPTIONS
}

usage() {
	echo -e ${CYAN} "Usage: $0 [-h|--help] [-p --path path] [-f|--force]"${NOCOLOR}
	echo
	echo -e ${CYAN} "Argmuments:"${NOCOLOR}
	echo -e ${CYAN} "  -h, --help    Display this help message"${NOCOLOR}
	echo -e ${CYAN} "  -f, --force   Force rebuild"${NOCOLOR}
	echo -e ${CYAN} "The default (no argument) will compile the firmware"${NOCOLOR}
	exit 1
}

force=false
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		;;
	-p | --path)
		path="$2"
		shift # past argument
		shift # past value
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

if [[ -z "$path" ]]; then
	error "No path specified. Use -p or --path to specify a path."
	exit 1
fi

pushd .
cd "$path" || exit
info "Export Zephyr CMake package..."
west zephyr-export
popd || exit
compile_firmware "$path" $force
