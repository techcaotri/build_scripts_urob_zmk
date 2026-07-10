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
	local boards_str shields_str snippets_str cmakeargs_str artifactnames_str
	boards_str="$(grep -E '^[[:space:]]*-[[:space:]]*board:' "$build_yaml" | sed 's/^.*: *//')"
	shields_str="$(_byfield shield)"
	snippets_str="$(_byfield snippet)"
	cmakeargs_str="$(_byfield cmake-args)"
	# artifact-name (optional): the GitHub-Actions output name. When present it is
	# used verbatim as the firmware filename (e.g. nice_sofle_right_touchpad),
	# which is clearer than the board_shield fallback for multi-shield entries.
	artifactnames_str="$(_byfield artifact-name)"
	local BOARDS SHIELDS SNIPPETS CMAKEARGS ARTIFACTS
	mapfile -t BOARDS <<< "$boards_str"
	mapfile -t SHIELDS <<< "$shields_str"
	mapfile -t SNIPPETS <<< "$snippets_str"
	mapfile -t CMAKEARGS <<< "$cmakeargs_str"
	mapfile -t ARTIFACTS <<< "$artifactnames_str"

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
		local shield_opts=() suffix bdir_key
		if [ -n "$sh" ]; then
			shield_opts=("-DSHIELD=$sh")
			suffix=$(echo "$sh" | awk '{print $1}')      # first shield word (output-name fallback)
			bdir_key=$(echo "$sh" | tr ' ' '_')          # full shield -> distinct build dir
		else
			suffix="nodisplay"; bdir_key="nodisplay"
		fi
		# Prefer the artifact-name for the build dir so entries sharing a first shield
		# word (e.g. two "sofle_left ..." display variants) don't collide on one dir.
		[ -n "${ARTIFACTS[i]}" ] && bdir_key="${ARTIFACTS[i]}"
		# Per-entry snippets (build.yaml `snippet:` plus -l logging) and cmake-args
		# (e.g. studio-rpc-usb-uart, which provides the zmk,studio-rpc-uart node).
		local snippet_opts=() extra_cmake=()
		[ "$zmk_logging" = true ] && snippet_opts+=(-S zmk-usb-logging)
		[ -n "${SNIPPETS[i]}" ] && snippet_opts+=(-S "${SNIPPETS[i]}")
		[ -n "${CMAKEARGS[i]}" ] && read -r -a extra_cmake <<< "${CMAKEARGS[i]}"
		local bdir="$ZMK_DIR/app/build/${bd}_${bdir_key}"
		info "Building $bd ${sh:-(no shield)}${SNIPPETS[i]:+ [snippet: ${SNIPPETS[i]}]} ..."
		# shellcheck disable=SC2086
		if west build $pristine -s "$ZMK_DIR/app" -d "$bdir" -b "$bd" "${snippet_opts[@]}" \
			-- -DZMK_CONFIG="$CONFIG_DIR/config" "${shield_opts[@]}" "${extra_cmake[@]}" \
			-DZMK_EXTRA_MODULES="$CONFIG_DIR" -Wno-dev; then
			local type=bin
			[ -f "$bdir/zephyr/zmk.uf2" ] && type=uf2
			# Output filename: prefer the build.yaml `artifact-name:` (e.g.
			# nice_sofle_right_touchpad); otherwise fall back to <board>_<shield>-zmk.
			local outbase="${bd}_${suffix}-zmk"
			[ -n "${ARTIFACTS[i]}" ] && outbase="${ARTIFACTS[i]}"
			local out="$output_dir/${outbase}.$type"
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
	# $3 is the -l/--zmk-logging boolean. IMPORTANT: leave the global `zmk_logging`
	# as that boolean -- the generic build path (compile_firmware_generic) checks
	# `[ "$zmk_logging" = true ]` to add the snippet, so overwriting it here (as this
	# used to) silently dropped USB logging on that path. Build the west snippet
	# string in a SEPARATE var for the zmk_build.sh (urob) path's WEST_OPTS.
	zmk_logging_opt=""
	if [ "$3" = true ]; then
		zmk_logging_opt="-S zmk-usb-logging"
	fi
	echo "zmk_logging: $zmk_logging (snippet: ${zmk_logging_opt:-none})"

  # Check if force_flag or the logging snippet is set, then add to WEST_OPTS
  if [ -n "$force_flag" ] || [ -n "$zmk_logging_opt" ]; then
    WEST_OPTS="-- $force_flag $zmk_logging_opt"
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

	# Test with -f (not -x) and invoke via `bash` so a checkout that lost the
	# executable bit -- e.g. a project copied by a tool that strips file modes --
	# still takes the urob path instead of silently falling back to the generic build
	# (which builds differently / handled -l separately). Consistent across machines.
	if [ -f "$CONFIG_DIR/scripts/zmk_build.sh" ]; then
		# urob layout: delegate to the config repo's lower-level builder.
		OPTIONS=" -l -o "$output_dir" --host-config-dir "$CONFIG_DIR" --host-zmk-dir "$ZMK_DIR" $board_opt $WEST_OPTS"
		echo bash "$CONFIG_DIR"/scripts/zmk_build.sh "$OPTIONS"
		bash "$CONFIG_DIR"/scripts/zmk_build.sh $OPTIONS
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
	echo -e ${CYAN} "Reference (zmk-config-rolio) shortcut — merged from build_rolio.sh:"${NOCOLOR}
	echo -e ${CYAN} "  --rolio [BRANCH]      Switch the bundled zmk-config-rolio checkout to BRANCH (default"${NOCOLOR}
	echo -e ${CYAN} "                        tps65-oled) and build it from its own source_rolio workspace. Sets -p,"${NOCOLOR}
	echo -e ${CYAN} "                        -c and -o for you; output defaults to output_uf2_rolio-<branch>"${NOCOLOR}
	echo -e ${CYAN} "                        (e.g. output_uf2_rolio-tps65-oled). -o/-p/-c still override."${NOCOLOR}
	echo -e ${CYAN} "  --rolio-dir DIR       Directory holding zmk-config-rolio + source_rolio (default: auto-detect"${NOCOLOR}
	echo -e ${CYAN} "                        Eyelash-Corne-Touchpad next to this script, or the current directory)."${NOCOLOR}
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
	echo -e ${CYAN} "  # Same, the easy way — build the rolio tps65-oled branch -> output_uf2_rolio-tps65-oled:"${NOCOLOR}
	echo -e ${CYAN} "  $0 --rolio -f"${NOCOLOR}
	echo -e ${CYAN} "  # Build a different rolio branch (-> output_uf2_rolio-master):"${NOCOLOR}
	echo -e ${CYAN} "  $0 --rolio master -f"${NOCOLOR}
	exit 1
}

force=false
zmk_logging=false
output_name="output_uf2"
output_name_set=false
path=""
board=""
config_dir=""
venv_dir=""
monitor=false
monitor_only=false
monitor_device=""
baud=115200
# --rolio convenience mode (folded in from build_rolio.sh): switch the bundled
# zmk-config-rolio checkout to a branch and build it from its own source_rolio
# workspace. rolio_dir holds zmk-config-rolio + source_rolio (auto-detected).
rolio_mode=false
rolio_branch=""
rolio_dir=""
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
		output_name_set=true
		shift # past argument
		shift # past value
		;;
	--rolio)
		# --rolio [BRANCH]: build the bundled zmk-config-rolio. An optional branch
		# name may follow (default tps65-oled); anything starting with '-' is left
		# for the normal parser (e.g. `--rolio -f`, `--rolio master -f`).
		rolio_mode=true
		if [[ -n "${2:-}" && "$2" != -* ]]; then
			rolio_branch="$2"
			shift
		fi
		shift
		;;
	--rolio-dir)
		# Directory that holds zmk-config-rolio + source_rolio (default: auto-detect
		# Eyelash-Corne-Touchpad next to this script, or the current directory).
		rolio_dir="$2"
		shift
		shift
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

# --- rolio convenience mode (merged from build_rolio.sh) ----------------------
# --rolio [BRANCH] switches the bundled zmk-config-rolio checkout to BRANCH
# (default tps65-oled) and builds it from its own source_rolio workspace, with
# the generic west build. Output defaults to output_uf2_rolio-<branch>
# (e.g. output_uf2_rolio-tps65-oled), overridable with -o.
if [ "$rolio_mode" = true ]; then
	[ -z "$rolio_branch" ] && rolio_branch="tps65-oled"

	# Locate the directory holding zmk-config-rolio + source_rolio.
	if [ -z "$rolio_dir" ]; then
		_scriptdir_real="$(dirname -- "$_real_script")"
		if [ -d "$PWD/zmk-config-rolio/.git" ]; then
			rolio_dir="$PWD"
		elif [ -d "$_scriptdir_real/../Eyelash-Corne-Touchpad/zmk-config-rolio/.git" ]; then
			rolio_dir="$(cd -- "$_scriptdir_real/../Eyelash-Corne-Touchpad" &>/dev/null && pwd)"
		else
			error "Cannot locate zmk-config-rolio. Pass --rolio-dir DIR (the directory"
			error "holding zmk-config-rolio + source_rolio), or run from Eyelash-Corne-Touchpad/."
			exit 1
		fi
	fi
	ROLIO_CFG="$rolio_dir/zmk-config-rolio"
	ROLIO_WS="$rolio_dir/source_rolio"
	[ -d "$ROLIO_CFG/.git" ] || { error "zmk-config-rolio not found at $ROLIO_CFG. Run ./setup_projects.sh first."; exit 1; }
	[ -e "$ROLIO_WS/zmk/app/west.yml" ] || { error "rolio workspace not prepared at $ROLIO_WS. Run ./setup_projects.sh first."; exit 1; }

	# Switch the config checkout to the requested branch (local or origin).
	info "==> rolio config branch: $rolio_branch"
	git -C "$ROLIO_CFG" fetch --quiet origin "$rolio_branch" 2>/dev/null || true
	if git -C "$ROLIO_CFG" show-ref --verify --quiet "refs/heads/$rolio_branch"; then
		git -C "$ROLIO_CFG" checkout -q "$rolio_branch" || { error "checkout $rolio_branch failed"; exit 1; }
	elif git -C "$ROLIO_CFG" show-ref --verify --quiet "refs/remotes/origin/$rolio_branch"; then
		git -C "$ROLIO_CFG" checkout -q -b "$rolio_branch" "origin/$rolio_branch" || { error "checkout origin/$rolio_branch failed"; exit 1; }
	else
		error "branch '$rolio_branch' not found locally or on origin."; exit 1
	fi
	info "    on $(git -C "$ROLIO_CFG" branch --show-current) @ $(git -C "$ROLIO_CFG" log --oneline -1)"

	# Derive path / config-dir / output-name unless the user set them explicitly.
	[ -z "$path" ] && path="$ROLIO_WS"
	[ -z "$config_dir" ] && config_dir="$ROLIO_CFG"
	[ "$output_name_set" = false ] && output_name="output_uf2_rolio-$rolio_branch"
fi

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
	# List the produced firmware (build_rolio.sh used to do this; keep it for --rolio
	# and any build so the user sees exactly what/where the .uf2 files are).
	_outdir_final="$(cd -- "$(dirname -- "$_real_script")" &>/dev/null && pwd)/$output_name"
	if [ -d "$_outdir_final" ]; then
		info "==> firmware in $_outdir_final :"
		ls -1 "$_outdir_final"/*.uf2 "$_outdir_final"/*.bin 2>/dev/null | sed 's#.*/#    #' || echo "    (none?)"
	fi
fi

if [ "$monitor" = true ] || [ "$monitor_only" = true ]; then
	monitor_serial "$monitor_device" "$baud"
fi
