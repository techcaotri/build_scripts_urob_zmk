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

show_help() {
	echo -e ${CYAN} "Usage: $0 [-h --help help] [-d --device device] [-p --path path] [-v --version version]"${NOCOLOR}
	echo
	echo -e ${CYAN} "Description:"${NOCOLOR}
	echo -e ${CYAN} "  Prepares the ZMK build environment for split keyboards based on urob's layout."${NOCOLOR}
	echo -e ${CYAN} "  Supported keyboards include Advantage360 Pro, Sofle v2, Sofle nicenano v2 choc, and Corne nicenano v2 choc."${NOCOLOR}
	echo
	echo -e ${CYAN} "Options:"${NOCOLOR}
	echo -e ${CYAN} "  -h, --help            Show this help message and exit."${NOCOLOR}
	echo -e ${CYAN} "  -d, --device DEVICE   Specify the device to prepare the build environment for."${NOCOLOR}
	echo -e ${CYAN} "                        Available devices: adv360-pro, sofle_v2, sofle_nicenano_v2, corne_nicenano_v2_choc, eyelash_corne, eyelash_corne_touchpad, eyelash_corne_dongle."${NOCOLOR}
	echo -e ${CYAN} "  -p, --path PATH       Specify the path for setting up the build environment."${NOCOLOR}
	echo -e ${CYAN} "  -y, --python PYTHON   Python interpreter used to create the .venv (e.g. python3.12)."${NOCOLOR}
	echo -e ${CYAN} "                        Defaults to the newest python3.x found. Zephyr 4.x needs >= 3.10."${NOCOLOR}
	echo -e ${CYAN} "  -v, --version         Display the current version of the script."${NOCOLOR}
}

show_version() {
	info "prepare_zmk_build_environment.sh version 1.0"
}

check_python_venv() {
	if [ -d .venv ]; then
		source .venv/bin/activate
	fi

	if [[ -z "$VIRTUAL_ENV" ]]; then
		# Resolve a suitable Python interpreter. The boards here pin Zephyr
		# v3.5.0+zmk-fixes, which is validated against Python 3.9 (and breaks on
		# 3.12 where distutils was removed), so default to python3.9. Newer Zephyr
		# (>= 4.x) needs >= 3.10 -- pass --python python3.12 in that case. An
		# explicit --python override always wins; otherwise fall back gracefully.
		local py="$python_bin"
		if [[ -z "$py" ]]; then
			for candidate in python3.9 python3.10 python3.11 python3.12 python3; do
				if command -v "$candidate" &>/dev/null; then
					py="$candidate"
					break
				fi
			done
		fi
		if [[ -z "$py" ]]; then
			error "No suitable Python interpreter found. Install Python (>= 3.10 for Zephyr 4.x)."
			exit 1
		fi
		info "Python virtual environment not detected. Creating one with '$py' ($("$py" --version 2>&1))..."
		if ! "$py" -m venv .venv; then
			error "Failed to create a Python virtual environment with '$py'."
			exit 1
		fi
		info "Virtual environment created at '.venv/'"
		source .venv/bin/activate
	else
		info "Running inside a Python virtual environment."
	fi
}

check_python_version() {
	python_version=$(python3 --version | cut -d " " -f 2)
	required_version="3.8"
	if [[ "$(printf '%s\n' "$required_version" "$python_version" | sort -V | head -n1)" = "$required_version" ]]; then
		info "Python version is $python_version."
	else
		error "Python version is $python_version, which is above the required version $required_version."
		exit 1
	fi
}

install_west() {
	if ! command -v west &>/dev/null; then
		info "West command not found. Installing west..."
		if ! pip install west; then
			error "Failed to install west."
			exit 1
		fi
	else
		info "West command is available."
	fi
  info "Installing west dependencies..."
  pip install pyelftools
}

# Link the locally-edited Azoteq IQS5xx driver (with the custom pinch-zoom and
# three-finger-swipe gestures) into the west workspace so the build compiles our
# code instead of the pristine upstream checkout fetched by `west update`.
#
# Layout: the editable driver lives next to the build workspace, i.e. at
# <workspace>/../zmk-driver-azoteq-iqs5xx. config/west.yml references the module
# by the name `zmk-driver-azoteq-iqs5xx`; we make that workspace path a symlink
# to the editable copy. Run from inside the workspace ($path).
link_local_iqs5xx_driver() {
	local driver_local
	driver_local="$(dirname "$(pwd)")/zmk-driver-azoteq-iqs5xx"

	if [ ! -d "$driver_local" ]; then
		info "Editable IQS5xx driver not found at $driver_local; cloning upstream as a base..."
		git clone https://github.com/AYM1607/zmk-driver-azoteq-iqs5xx.git "$driver_local" || {
			error "Failed to clone the Azoteq IQS5xx driver."
			return 1
		}
	fi

	# Replace whatever west placed at the module path with a symlink to our copy.
	if [ ! -L zmk-driver-azoteq-iqs5xx ]; then
		rm -rf zmk-driver-azoteq-iqs5xx
	fi
	ln -sfn "$driver_local" zmk-driver-azoteq-iqs5xx
	info "Linked Azoteq IQS5xx driver: $(pwd)/zmk-driver-azoteq-iqs5xx -> $driver_local"
}

prepare_adv360_pro() {
	info "Preparing environment for Advantage360 Pro"
	# Add specific steps for Advantage360 Pro

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Advantage360 Pro"
		git clone --recurse-submodules -j8 -b tripham_adv360_pro git@github.com:techcaotri/from-urob-zmk-config.git
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_sofle_v2() {
	info "Preparing environment for Sofle v2"
	# Add specific steps for Sofle v2

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Sofle v2"
		git clone --recurse-submodules -j8 -b tripham_sofle git@github.com:techcaotri/from-urob-zmk-config.git
	fi

  info "Checking new keypos_def header file exist..."
	if [ ! -f from-urob-zmk-config/zmk-nodefree-config/keypos_def/keypos_60keys.h ]; then
    info "Create soft link for config west.yml file..."
    pushd .
    cd from-urob-zmk-config/zmk-nodefree-config/keypos_def
    ln -sf ../../keypos_def/keypos_60keys.h .
    popd
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_sofle_nicenano_v2() {
	info "Preparing environment for Sofle nicenano v2 choc"
	# Add specific steps for Sofle nicenano v2 choc

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Sofle nicenano v2 choc"
		git clone --recurse-submodules -j8 -b tripham_choc_nicenanov2_sofle git@github.com:techcaotri/from-urob-zmk-config.git
	fi

  info "Checking new keypos_def header file exist..."
	if [ ! -f from-urob-zmk-config/zmk-nodefree-config/keypos_def/keypos_60keys.h ]; then
    info "Create soft link for config west.yml file..."
    pushd .
    cd from-urob-zmk-config/zmk-nodefree-config/keypos_def
    ln -sf ../../keypos_def/keypos_60keys.h .
    popd
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_corne_nicenano_v2_choc() {
	info "Preparing environment for Corne nicenano v2 choc"
	# Add specific steps for Corne nicenano v2 choc

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Corne nicenano v2 choc"
		git clone --recurse-submodules -j8 -b tripham_corne_choc git@github.com:techcaotri/from-urob-zmk-config.git
	fi

  info "Checking new keypos_def header file exist..."
	if [ ! -f from-urob-zmk-config/zmk-nodefree-config/keypos_def/keypos_60keys.h ]; then
    info "Create soft link for config west.yml file..."
    pushd .
    cd from-urob-zmk-config/zmk-nodefree-config/keypos_def
    ln -sf ../../keypos_def/keypos_42keys.h .
    popd
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_eyelash_corne() {
	info "Preparing environment for Eyelash Corne nicenano"
	# Add specific steps for Eyelash Corne nicenano

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Eyelash Corne nicenano"
		git clone --recurse-submodules -j8 -b eyelash_corne git@github.com:techcaotri/from-urob-zmk-config.git
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_eyelash_corne_touchpad() {
	info "Preparing environment for Eyelash Corne nicenano With Touchpad"
	# Add specific steps for Eyelash Corne nicenano With Touchpad

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Eyelash Corne nicenano With Touchpad"
		git clone --recurse-submodules -j8 -b eyelash_corne_touchpad git@github.com:techcaotri/from-urob-zmk-config.git
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  else
    info "Workspace exists; fetching any newly-added west modules (e.g. the touchpad driver)..."
    west update zmk-driver-azoteq-iqs5xx || west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Linking the local Azoteq IQS5xx touchpad driver into the workspace..."
  link_local_iqs5xx_driver

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

prepare_eyelash_corne_dongle() {
	info "Preparing environment for Eyelash Corne nicenano With Dongle Receiver"
	# Add specific steps for Eyelash Corne nicenano With Dongle Receiver

	info "Checking source from-urob-zmk-config file exist..."
	if [ ! -d from-urob-zmk-config ]; then
    info "Cloning source from-urob-zmk-config directory for Eyelash Corne nicenano With Dongle Receiver"
		git clone --recurse-submodules -j8 -b eyelash_corne_dongle git@github.com:techcaotri/from-urob-zmk-config.git
	fi

	info "Checking config file exist..."
	if [ ! -f config/west.yml ]; then
    info "Create soft link for config west.yml file..."
		mkdir -p config && cd config
    ln -sf "$(pwd)/../from-urob-zmk-config/config/west.yml" .
		cd ..
	fi

  info "Checking build.yml file exist..."
	if [ ! -f build.yaml ]; then
    info "Create soft link for build.yaml file exist..."
    ln -sf from-urob-zmk-config/build.yaml .
  fi

	info "Checking zmk directory exist..."
  if [ ! -d zmk ]; then
    info "Initializing folders according to current config..."
    west init -l config
    info "Updating source folders..."
    west update
  fi

  info "Exporting CMake build environment variables..."
  west zephyr-export

  info "Installing Python requirements..."
  pip install -r zephyr/scripts/requirements.txt
}

# Default values
device=""
python_bin=""

# Parse command-line options
while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		exit 0
		;;
	-d | --device)
		device="$2"
		shift # past argument
		shift # past value
		;;
	-p | --path)
		path="$2"
		shift # past argument
		shift # past value
		;;
	-y | --python)
		python_bin="$2"
		shift # past argument
		shift # past value
		;;
	-v | --version)
		show_version
		exit 0
		;;
	*) # unknown option
		error "Unknown option: $1"
		show_help
		exit 1
		;;
	esac
done

if [[ -z "$path" ]]; then
	error "No path specified. Use -p or --path to specify a path."
	exit 1
fi

mkdir -p "$path" && cd "$path" || exit 1

# Main script logic
check_python_venv
check_python_version
install_west

info "Preparing build environment for device: $device"
# Add the rest of your script logic here
# Main script logic
case $device in
adv360-pro)
	prepare_adv360_pro
	;;
sofle_v2)
	prepare_sofle_v2
	;;
sofle_nicenano_v2)
	prepare_sofle_nicenano_v2
	;;
corne_nicenano_v2_choc)
	prepare_corne_nicenano_v2_choc
	;;
eyelash_corne)
	prepare_eyelash_corne
	;;
eyelash_corne_touchpad)
	prepare_eyelash_corne_touchpad
	;;
eyelash_corne_dongle)
	prepare_eyelash_corne_dongle
	;;
"")
	error "No device specified. Use -d or --device to specify a device."
	exit 1
	;;
*)
	error "Unsupported device: $device"
	exit 1
	;;
esac
