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
	echo -e ${CYAN} "  Supported keyboards include Advantage360 Pro, Sofle v2, and Sofle nicenano v2 choc."${NOCOLOR}
	echo
	echo -e ${CYAN} "Options:"${NOCOLOR}
	echo -e ${CYAN} "  -h, --help            Show this help message and exit."${NOCOLOR}
	echo -e ${CYAN} "  -d, --device DEVICE   Specify the device to prepare the build environment for."${NOCOLOR}
	echo -e ${CYAN} "                        Available devices: adv360-pro, sofle_v2, sofle_nicenano_v2."${NOCOLOR}
	echo -e ${CYAN} "  -p, --path PATH       Specify the path for setting up the build environment."${NOCOLOR}
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
		info "Python virtual environment not detected. Creating one..."
		if ! python3.9 -m venv .venv; then
			error "Failed to create Python 3.9 virtual environment."
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

# Default values
device=""

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
"")
	error "No device specified. Use -d or --device to specify a device."
	exit 1
	;;
*)
	error "Unsupported device: $device"
	exit 1
	;;
esac
