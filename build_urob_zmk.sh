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

# The shared Python virtualenv lives one level above this script's repository
# (e.g. .../Sources/.venv) and is reused across keyboard projects. Resolve
# symlinks first so this holds whether the script is run directly or via a
# symlink elsewhere (e.g. Eyelash-Corne-Touchpad/build_urob_zmk.sh). Override
# with -e/--venv.
_real_script="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
[ -z "$_real_script" ] && _real_script="${BASH_SOURCE[0]}"
DEFAULT_VENV="$(cd -- "$(dirname -- "$_real_script")/.." &>/dev/null && pwd)/.venv"

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

# Build a *standard* ZMK config that does NOT ship from-urob-zmk-config/scripts/
# zmk_build.sh (e.g. zmk-config-rolio: a config/ + build.yaml + a boards/ module).
# Mirrors, inline, the `west build` invocation the urob zmk_build.sh would make.
# Uses globals: SOURCE_DIR, CONFIG_DIR, ZMK_DIR, output_dir, force, zmk_logging, board.
compile_firmware_generic() {
	local build_yaml="$CONFIG_DIR/build.yaml"
	if [ ! -f "$build_yaml" ]; then
		error "No build.yaml found at $build_yaml"
		return 1
	fi

	# Parse the build.yaml include list into index-aligned arrays. For every
	# "- board:" entry emit exactly one value of board / shield / snippet /
	# cmake-args (empty when the field is absent), read with mapfile so blank
	# values survive as array elements (plain word-splitting would drop them).
	_byfield() {
		awk -v key="$1" '
			/^[[:space:]]*-[[:space:]]*board:/ { if (seen) print v; v=""; seen=1; next }
			$0 ~ ("^[[:space:]]*" key ":") { s=$0; sub(/^[^:]*:[[:space:]]*/,"",s); v=s }
			END { if (seen) print v }
		' "$build_yaml"
	}
	local boards_str shields_str snippets_str cmakeargs_str
	boards_str="$(grep -E '^[[:space:]]*-[[:space:]]*board:' "$build_yaml" | sed 's/^.*: *//')"
	shields_str="$(_byfield shield)"
	snippets_str="$(_byfield snippet)"
	cmakeargs_str="$(_byfield cmake-args)"
	local BOARDS SHIELDS SNIPPETS CMAKEARGS
	mapfile -t BOARDS <<< "$boards_str"
	mapfile -t SHIELDS <<< "$shields_str"
	mapfile -t SNIPPETS <<< "$snippets_str"
	mapfile -t CMAKEARGS <<< "$cmakeargs_str"

	local pristine=""
	[ "$force" = true ] && pristine="-p"

	cd "$SOURCE_DIR" || return 1
	local i ok=0 total=0
	for ((i = 0; i < ${#BOARDS[@]}; i++)); do
		local bd="${BOARDS[i]}" sh="${SHIELDS[i]}"
		[ -z "$bd" ] && continue
		# Optional -b board filter.
		if [ -n "$board" ]; then
			case " ${board//,/ } " in *" $bd "*) ;; *) continue ;; esac
		fi
		total=$((total + 1))
		local shield_opts=() suffix
		if [ -n "$sh" ]; then
			shield_opts=("-DSHIELD=$sh")
			suffix=$(echo "$sh" | awk '{print $1}')
		else
			suffix="nodisplay"
		fi
		# Per-entry snippets (build.yaml `snippet:` plus -l logging) and cmake-args
		# (e.g. studio-rpc-usb-uart, which provides the zmk,studio-rpc-uart node).
		local snippet_opts=() extra_cmake=()
		[ "$zmk_logging" = true ] && snippet_opts+=(-S zmk-usb-logging)
		[ -n "${SNIPPETS[i]}" ] && snippet_opts+=(-S "${SNIPPETS[i]}")
		[ -n "${CMAKEARGS[i]}" ] && read -r -a extra_cmake <<< "${CMAKEARGS[i]}"
		local bdir="$ZMK_DIR/app/build/${bd}_${suffix}"
		info "Building $bd ${sh:-(no shield)}${SNIPPETS[i]:+ [snippet: ${SNIPPETS[i]}]} ..."
		# shellcheck disable=SC2086
		if west build $pristine -s "$ZMK_DIR/app" -d "$bdir" -b "$bd" "${snippet_opts[@]}" \
			-- -DZMK_CONFIG="$CONFIG_DIR/config" "${shield_opts[@]}" "${extra_cmake[@]}" \
			-DZMK_EXTRA_MODULES="$CONFIG_DIR" -Wno-dev; then
			local type=bin
			[ -f "$bdir/zephyr/zmk.uf2" ] && type=uf2
			local out="$output_dir/${bd}_${suffix}-zmk.$type"
			[ -f "$out" ] && [ ! -L "$out" ] && mv "$out" "$out.bak"
			cp "$bdir/zephyr/zmk.$type" "$out"
			info "  -> $out"
			ok=$((ok + 1))
		else
			error "  build FAILED for $bd ${sh:-(no shield)}"
		fi
	done
	info "Generic ZMK build: $ok/$total board(s) succeeded -> $output_dir"
	[ "$ok" -eq "$total" ] && [ "$total" -gt 0 ]
}

compile_firmware() {
	SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
	info "SCRIPT_DIR: $SCRIPT_DIR"
	SOURCE_DIR=$(realpath "$1")
	info "SOURCE_DIR: $SOURCE_DIR"
	# CONFIG_DIR is the ZMK config repo. Default to the urob layout
	# ($SOURCE_DIR/from-urob-zmk-config); override with -c/--config-dir for a
	# standard ZMK config that lives elsewhere (e.g. zmk-config-rolio).
	if [ -n "$config_dir" ]; then
		CONFIG_DIR="$(realpath "$config_dir")"
	else
		CONFIG_DIR="$SOURCE_DIR/from-urob-zmk-config"
	fi
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

	pushd .
	cd "$SOURCE_DIR" || exit
  west zephyr-export
  popd || exit

	if [ -x "$CONFIG_DIR/scripts/zmk_build.sh" ]; then
		# urob layout: delegate to the config repo's lower-level builder.
		OPTIONS=" -l -o "$output_dir" --host-config-dir "$CONFIG_DIR" --host-zmk-dir "$ZMK_DIR" $board_opt $WEST_OPTS"
		echo "$CONFIG_DIR"/scripts/zmk_build.sh "$OPTIONS"
		"$CONFIG_DIR"/scripts/zmk_build.sh $OPTIONS
	else
		# Standard ZMK config without scripts/zmk_build.sh (e.g. zmk-config-rolio):
		# build each build.yaml entry directly with west.
		info "No $CONFIG_DIR/scripts/zmk_build.sh -> using the built-in generic ZMK build."
		compile_firmware_generic
	fi
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
	echo -e ${CYAN} "  -c, --config-dir DIR  ZMK config repo to build. Default: PATH/from-urob-zmk-config (urob layout)."${NOCOLOR}
	echo -e ${CYAN} "                        Point at a standard ZMK config (e.g. zmk-config-rolio) to build it via"${NOCOLOR}
	echo -e ${CYAN} "                        the built-in generic west build (no scripts/zmk_build.sh needed)."${NOCOLOR}
	echo -e ${CYAN} "  -e, --venv DIR        Python virtualenv to activate. Default: the shared venv next to this"${NOCOLOR}
	echo -e ${CYAN} "                        script's repo ($DEFAULT_VENV);"${NOCOLOR}
	echo -e ${CYAN} "                        falls back to an active \$VIRTUAL_ENV, then PATH/.venv."${NOCOLOR}
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
	echo -e ${CYAN} "  # Build a standard ZMK config (zmk-config-rolio) from its own workspace:"${NOCOLOR}
	echo -e ${CYAN} "  $0 -p source_rolio -c ../Eyelash-Corne-Touchpad/zmk-config-rolio -o output_uf2_rolio -f"${NOCOLOR}
	exit 1
}

force=false
zmk_logging=false
output_name="output_uf2"
board=""
config_dir=""
venv_dir=""
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
	-c | --config-dir)
		config_dir="$2"
		shift # past argument
		shift # past value
		;;
	-e | --venv)
		venv_dir="$2"
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

# Resolve the Python virtualenv to activate. Precedence:
#   1. -e/--venv DIR (explicit)
#   2. the shared venv next to this script's repo ($DEFAULT_VENV, e.g. Sources/.venv)
#   3. the per-workspace $path/.venv (legacy)
#   4. an already-active $VIRTUAL_ENV (only if none of the above exist)
# The shared venv is preferred even when some venv is already active in the shell,
# so the default is deterministic; pass -e/--venv to force a specific one.
venv=""
if [ -n "$venv_dir" ]; then
	venv="$venv_dir"
elif [ -f "$DEFAULT_VENV/bin/activate" ]; then
	venv="$DEFAULT_VENV"
elif [ -f "$path/.venv/bin/activate" ]; then
	venv="$path/.venv"
fi

if [ -n "$venv" ]; then
	if [ ! -f "$venv/bin/activate" ]; then
		error "Virtualenv has no bin/activate: $venv"
		exit 1
	fi
	info "Activating Python virtual environment: $venv"
	# shellcheck disable=SC1091
	source "$venv/bin/activate"
	info "$(command -v python)"
	if [ -z "$VIRTUAL_ENV" ]; then
		error "Failed to activate the virtual environment at $venv."
		exit 1
	fi
elif [ -n "$VIRTUAL_ENV" ]; then
	info "Using already-active virtual environment: $VIRTUAL_ENV"
else
	error "No Python virtualenv found. Pass -e/--venv DIR, create $DEFAULT_VENV,"
	error "or run prepare_zmk_build_environment.sh for $path."
	exit 1
fi
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
