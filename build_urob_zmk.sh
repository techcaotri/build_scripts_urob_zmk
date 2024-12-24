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

error() {
	echo -e "${RED}$@${NOCOLOR}" >&2
}

compile_firmware() {
	SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
	info "SCRIPT_DIR: $SCRIPT_DIR"
	SOURCE_DIR=$(realpath "$1")
	info "SOURCE_DIR: $SOURCE_DIR"
	CONFIG_DIR="$(realpath "$1")/from-urob-zmk-config"
	info "CONFIG_DIR: $CONFIG_DIR"
	ZMK_DIR="$SOURCE_DIR/zmk"
	info "ZMK_DIR: $ZMK_DIR"
	ZEPHYR_DIR="$SOURCE_DIR/zephyr"
	info "ZEPHYR_DIR: $ZEPHYR_DIR"
	zephyr_version=$(awk -F ' *= *' '/VERSION_MAJOR/ {major=$2} /VERSION_MINOR/ {minor=$2} /PATCHLEVEL/ {patch=$2} END {printf "%d%d%d", major, minor, patch}' "$ZEPHYR_DIR/VERSION")
	info "zephyr_version: $zephyr_version"

	force_flag=""
	if [ $2 = true ]; then
		force_flag="-- -p"
	fi
	echo "force_flag: $force_flag"
	output_dir="$SCRIPT_DIR/output_uf2"
	mkdir -p "$output_dir"
	OPTIONS=" -l -o "$output_dir" --host-config-dir "$CONFIG_DIR" --host-zmk-dir "$ZMK_DIR" $force_flag"

	pushd .
	cd "$SOURCE_DIR" || exit
  west zephyr-export
  popd || exit

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
		exit 0
		;;
	-p | --path)
		path="$2"
		shift # past argument
		shift # past value
		;;
	-f | --force)
		force=true
		shift
		;;
	*)
		usage
		exit 1
		;;
	esac
done

if [[ -z "$path" ]]; then
	error "No path specified. Use -p or --path to specify a path."
	exit 1
fi

pushd .
cd "$path" || exit
if [ -d .venv ]; then
  info "Found .venv directory at $(pwd)/.venv . Activating this Python virtual environment..."
  source .venv/bin/activate
  info "$(which python)"
	if [[ -z "$VIRTUAL_ENV" ]]; then
		error "Python virtual environment not detected."
		exit 1
	else
		info "Running inside a Python virtual environment."
	fi
else
	error "No .venv directory found. Please run prepare_zmk_build_environment.sh first."
	exit 1
fi

popd || exit
echo "force: $force"
compile_firmware "$path" $force
