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

# Open a serial monitor on the keyboard's USB-CDC console (the half built with the
# zmk-usb-logging snippet, see -l). Used to watch the IQS5xx driver's LOG_INF /
# LOG_ERR output while testing and tuning gestures (gestures guide section 9).
#
# Tries, in order: the venv's pyserial miniterm (no sudo, installed by prepare),
# then tio / picocom / screen. Quit keys differ per tool (printed below).
monitor_serial() {
	local dev="$1" baud="$2"
	[[ -z "$baud" ]] && baud=115200

	# Auto-detect the first USB-CDC ACM device when none was given.
	if [[ -z "$dev" ]]; then
		dev=$(ls /dev/ttyACM* 2>/dev/null | head -n1)
		# macOS / other CDC names as a fallback.
		[[ -z "$dev" ]] && dev=$(ls /dev/tty.usbmodem* /dev/ttyUSB* 2>/dev/null | head -n1)
	fi
	if [[ -z "$dev" ]]; then
		error "No serial device found (looked for /dev/ttyACM*). Plug in the half built"
		error "with -l/--zmk-logging, or pass --monitor-device /dev/ttyACMx."
		return 1
	fi
	if [[ ! -e "$dev" ]]; then
		error "Serial device '$dev' does not exist."
		return 1
	fi

	info "Opening serial monitor on $dev @ ${baud} baud..."
	if python -c 'import serial.tools.miniterm' &>/dev/null; then
		info "  (pyserial miniterm — quit with Ctrl-])"
		python -m serial.tools.miniterm "$dev" "$baud"
	elif command -v tio &>/dev/null; then
		info "  (tio — quit with Ctrl-t then q)"
		tio -b "$baud" "$dev"
	elif command -v picocom &>/dev/null; then
		info "  (picocom — quit with Ctrl-a then Ctrl-x)"
		picocom -b "$baud" "$dev"
	elif command -v screen &>/dev/null; then
		info "  (screen — quit with Ctrl-a then k)"
		screen "$dev" "$baud"
	else
		error "No serial monitor available. Install one of:"
		error "  pip install pyserial   (then re-run; preferred, no sudo)"
		error "  sudo apt install tio   |   picocom   |   screen"
		return 1
	fi
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
	# Pin the Zephyr used by find_package(Zephyr) to THIS workspace. Every prepared
	# variant registers its zephyr in ~/.cmake/packages/Zephyr, so without this the
	# CMake user package registry may resolve to a different variant's Zephyr. With
	# ZEPHYR_BASE set, Zephyr's version check rejects every registered copy but this one.
	export ZEPHYR_BASE="$ZEPHYR_DIR"
	info "ZEPHYR_BASE: $ZEPHYR_BASE"
	zephyr_version=$(awk -F ' *= *' '/VERSION_MAJOR/ {major=$2} /VERSION_MINOR/ {minor=$2} /PATCHLEVEL/ {patch=$2} END {printf "%d%d%d", major, minor, patch}' "$ZEPHYR_DIR/VERSION")
	info "zephyr_version: $zephyr_version"

	# Touchpad: if this config pulls in the Azoteq IQS5xx driver, make sure the
	# module is actually present in the workspace (it is linked there by
	# prepare_zmk_build_environment.sh). Otherwise the touchpad + custom gesture
	# code would silently not be compiled.
	if grep -q "zmk-driver-azoteq-iqs5xx" "$CONFIG_DIR/config/west.yml" 2>/dev/null &&
		[ ! -e "$SOURCE_DIR/zmk-driver-azoteq-iqs5xx/zephyr/module.yml" ]; then
		error "west.yml references zmk-driver-azoteq-iqs5xx but the module is missing under $SOURCE_DIR."
		error "Run: $SCRIPT_DIR/prepare_zmk_build_environment.sh -d eyelash_corne_touchpad -p $SOURCE_DIR"
	fi

	force_flag=""
	if [ $2 = true ]; then
		force_flag="-p"
	fi
	echo "force_flag: $force_flag"
	zmk_logging=""
	if [ $3 = true ]; then
		zmk_logging="-S zmk-usb-logging"
	fi
	echo "zmk_logging: $zmk_logging"

  # Check if force_flag or zmk_logging is set, then add to WEST_OPTS
  if [ -n "$force_flag" ] || [ -n "$zmk_logging" ]; then
    WEST_OPTS="-- $force_flag $zmk_logging"
  else
    WEST_OPTS=""
  fi
	echo "WEST_OPTS: $WEST_OPTS"
	output_name="${4:-output_uf2}"
	output_dir="$SCRIPT_DIR/$output_name"
	info "output_dir: $output_dir"
	mkdir -p "$output_dir"

	# Optional board filter: build only the matching build.yaml entries (e.g.
	# just the peripheral half with logging: -b eyelash_corne_right -l).
	board_opt=""
	if [ -n "$board" ]; then
		board_opt="-b $board"
		info "board filter: $board"
	fi

	OPTIONS=" -l -o "$output_dir" --host-config-dir "$CONFIG_DIR" --host-zmk-dir "$ZMK_DIR" $board_opt $WEST_OPTS"

	pushd .
	cd "$SOURCE_DIR" || exit
  west zephyr-export
  popd || exit

	echo "$CONFIG_DIR"/scripts/zmk_build.sh "$OPTIONS"
	"$CONFIG_DIR"/scripts/zmk_build.sh $OPTIONS
}

usage() {
	echo -e ${CYAN} "Usage: $0 -p PATH [options]"${NOCOLOR}
	echo
	echo -e ${CYAN} "Build options:"${NOCOLOR}
	echo -e ${CYAN} "  -h, --help            Display this help message"${NOCOLOR}
	echo -e ${CYAN} "  -p, --path PATH       Workspace path (the same -p used with prepare_zmk_build_environment.sh). Required."${NOCOLOR}
	echo -e ${CYAN} "  -o, --output-name N   Output sub-directory (under the script dir) for the .uf2/.bin. Default: output_uf2"${NOCOLOR}
	echo -e ${CYAN} "  -f, --force           Force a clean (pristine) rebuild"${NOCOLOR}
	echo -e ${CYAN} "  -b, --board BOARD     Build only build.yaml entries for this board (e.g. eyelash_corne_right)."${NOCOLOR}
	echo -e ${CYAN} "                        Comma/space separated for several. Default: every entry in build.yaml."${NOCOLOR}
	echo
	echo -e ${CYAN} "Testing / logging / tuning (see the gestures guide, section 9):"${NOCOLOR}
	echo -e ${CYAN} "  -l, --zmk-logging     Build with the zmk-usb-logging snippet (USB-CDC serial console for LOG_INF/LOG_ERR)."${NOCOLOR}
	echo -e ${CYAN} "  -m, --monitor         After building, open a serial monitor on the logging half's USB-CDC device."${NOCOLOR}
	echo -e ${CYAN} "      --monitor-only    Skip building; just open the serial monitor."${NOCOLOR}
	echo -e ${CYAN} "      --monitor-device D   Serial device to monitor (default: auto-detect /dev/ttyACM*)."${NOCOLOR}
	echo -e ${CYAN} "      --baud RATE       Serial monitor baud rate. Default: 115200."${NOCOLOR}
	echo
	echo -e ${CYAN} "Examples:"${NOCOLOR}
	echo -e ${CYAN} "  # Build everything, clean:"${NOCOLOR}
	echo -e ${CYAN} "  $0 -p WS -o out_tp -f"${NOCOLOR}
	echo -e ${CYAN} "  # Debug the touchpad: build ONLY the right/peripheral half with logging, then watch logs:"${NOCOLOR}
	echo -e ${CYAN} "  $0 -p WS -o out_tp -b eyelash_corne_right -l -f -m"${NOCOLOR}
	echo -e ${CYAN} "  # Just re-open the serial monitor (firmware already flashed):"${NOCOLOR}
	echo -e ${CYAN} "  $0 -p WS --monitor-only"${NOCOLOR}
	exit 1
}

force=false
zmk_logging=false
output_name="output_uf2"
board=""
monitor=false
monitor_only=false
monitor_device=""
baud=115200
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
	-o | --output-name)
		output_name="$2"
		shift # past argument
		shift # past value
		;;
	-f | --force)
		force=true
		shift
		;;
	-b | --board)
		board="$2"
		shift # past argument
		shift # past value
		;;
  -l | --zmk-logging)
    zmk_logging=true
    shift
    ;;
	-m | --monitor)
		monitor=true
		shift
		;;
	--monitor-only)
		monitor_only=true
		shift
		;;
	--monitor-device)
		monitor_device="$2"
		shift
		shift
		;;
	--baud)
		baud="$2"
		shift
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
  if [[ -z "$VIRTUAL_ENV" ]]; then
		error "Neither .venv directory found nor Python virtual environment not detected. Please run prepare_zmk_build_environment.sh first."
    exit 1
  fi
fi

popd || exit
echo "force: $force"

export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR=~/zephyr_sdk/

if [ "$monitor_only" = true ]; then
	info "Skipping build (--monitor-only)."
else
	compile_firmware "$path" $force "$zmk_logging" "$output_name"
fi

if [ "$monitor" = true ] || [ "$monitor_only" = true ]; then
	monitor_serial "$monitor_device" "$baud"
fi
