# prepare_host_basic
#
# * installs only basic packages
#
prepare_host_basic() {

	# command:package1 package2 ...
	# list of commands that are neeeded:packages where this command is
	local check_pack install_pack
	local checklist=(
		"dialog:dialog"
		"fuser:psmisc"
		"getfacl:acl"
		"uuid:uuid uuid-runtime"
		"curl:curl"
		"gpg:gnupg"
		"gawk:gawk"
	)

	for check_pack in "${checklist[@]}"; do
		if ! which ${check_pack%:*} > /dev/null; then local install_pack+=${check_pack#*:}" "; fi
	done

	if [[ -n $install_pack ]]; then
		display_alert "Installing basic packages" "$install_pack"
		sudo bash -c "apt-get -qq update && apt-get install -qq -y --no-install-recommends $install_pack"
	fi

}

# prepare_host
#
# * checks and installs necessary packages
# * creates directory structure
# * changes system settings
#
prepare_host() {
	display_alert "Preparing" "host" "info"

	# The 'offline' variable must always be set to 'true' or 'false'
	if [ "$OFFLINE_WORK" == "yes" ]; then
		local offline=true
	else
		local offline=false
	fi

	# wait until package manager finishes possible system maintanace
	wait_for_package_manager

	# fix for Locales settings
	if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
		sudo sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
		sudo locale-gen
	fi

	export LC_ALL="en_US.UTF-8"

	# packages list for host
	# NOTE: please sync any changes here with the Dockerfile and Vagrantfile

	local hostdeps="acl aptly aria2 bc binfmt-support bison btrfs-progs       \
	build-essential  ca-certificates ccache cpio cryptsetup curl              \
	debian-archive-keyring debian-keyring debootstrap device-tree-compiler    \
	dialog dirmngr dosfstools dwarves f2fs-tools fakeroot flex gawk           \
	gcc-arm-linux-gnueabihf gdisk gnupg1 gpg imagemagick jq kmod libbison-dev \
	libc6-dev-armhf-cross libelf-dev libfdt-dev libfile-fcntllock-perl        \
	libfl-dev liblz4-tool libncurses-dev libpython2.7-dev libssl-dev          \
	libusb-1.0-0-dev linux-base locales lzop ncurses-base ncurses-term        \
	nfs-kernel-server ntpdate p7zip-full parted patchutils pigz pixz          \
	pkg-config pv python3-dev python3-distutils qemu-user-static rsync swig   \
	systemd-container u-boot-tools udev unzip uuid-dev wget whiptail zip      \
	zlib1g-dev file"

	if [[ $(dpkg --print-architecture) == amd64 ]]; then

		hostdeps+=" distcc lib32ncurses-dev lib32stdc++6 libc6-i386"
		grep -q i386 <(dpkg --print-foreign-architectures) || dpkg --add-architecture i386

	elif [[ $(dpkg --print-architecture) == arm64 ]]; then

		hostdeps+=" gcc-arm-linux-gnueabi gcc-arm-none-eabi libc6 libc6-amd64-cross qemu"

	else

		display_alert "Please read documentation to set up proper compilation environment"
		display_alert "https://www.armbian.com/using-armbian-tools/"
		exit_with_error "Running this tool on non x86_64 build host is not supported"

	fi

	# Add support for Ubuntu 20.04, 21.04 and Mint 20.x
	if [[ $HOSTRELEASE =~ ^(focal|impish|hirsute|ulyana|ulyssa|bullseye|uma)$ ]]; then
		hostdeps+=" python2 python3"
		ln -fs /usr/bin/python2.7 /usr/bin/python2
		ln -fs /usr/bin/python2.7 /usr/bin/python
	else
		hostdeps+=" python libpython-dev"
	fi

	display_alert "Build host OS release" "${HOSTRELEASE:-(unknown)}" "info"

	# Ubuntu 21.04.x (Hirsute) x86_64 is the only fully supported host OS release
	# Using Docker/VirtualBox/Vagrant is the only supported way to run the build script on other Linux distributions
	#
	# NO_HOST_RELEASE_CHECK overrides the check for a supported host system
	# Disable host OS check at your own risk. Any issues reported with unsupported releases will be closed without discussion
	if [[ -z $HOSTRELEASE || "buster bullseye focal impish hirsute debbie tricia ulyana ulyssa uma" != *"$HOSTRELEASE"* ]]; then
		if [[ $NO_HOST_RELEASE_CHECK == yes ]]; then
			display_alert "You are running on an unsupported system" "${HOSTRELEASE:-(unknown)}" "wrn"
			display_alert "Do not report any errors, warnings or other issues encountered beyond this point" "" "wrn"
		else
			exit_with_error "It seems you ignore documentation and run an unsupported build system: ${HOSTRELEASE:-(unknown)}"
		fi
	fi

	if grep -qE "(Microsoft|WSL)" /proc/version; then
		if [ -f /.dockerenv ]; then
			display_alert "Building images using Docker on WSL2 may fail" "" "wrn"
		else
			exit_with_error "Windows subsystem for Linux is not a supported build environment"
		fi
	fi

	if systemd-detect-virt -q -c; then
		display_alert "Running in container" "$(systemd-detect-virt)" "info"
		# disable apt-cacher unless NO_APT_CACHER=no is not specified explicitly
		if [[ $NO_APT_CACHER != no ]]; then
			display_alert "apt-cacher is disabled in containers, set NO_APT_CACHER=no to override" "" "wrn"
			NO_APT_CACHER=yes
		fi
		CONTAINER_COMPAT=yes
		# trying to use nested containers is not a good idea, so don't permit EXTERNAL_NEW=compile
		if [[ $EXTERNAL_NEW == compile ]]; then
			display_alert "EXTERNAL_NEW=compile is not available when running in container, setting to prebuilt" "" "wrn"
			EXTERNAL_NEW=prebuilt
		fi
		SYNC_CLOCK=no
	fi

	# Skip verification if you are working offline
	if ! $offline; then

		# warning: apt-cacher-ng will fail if installed and used both on host and in
		# container/chroot environment with shared network
		# set NO_APT_CACHER=yes to prevent installation errors in such case
		if [[ $NO_APT_CACHER != yes ]]; then hostdeps+=" apt-cacher-ng"; fi

		export EXTRA_BUILD_DEPS=""
		call_extension_method "add_host_dependencies" <<- 'ADD_HOST_DEPENDENCIES'
			*run before installing host dependencies*
			you can add packages to install, space separated, to ${EXTRA_BUILD_DEPS} here.
		ADD_HOST_DEPENDENCIES

		if [ -n "${EXTRA_BUILD_DEPS}" ]; then hostdeps+=" ${EXTRA_BUILD_DEPS}"; fi

		display_alert "Installing build dependencies"
		# don't prompt for apt cacher selection
		sudo echo "apt-cacher-ng    apt-cacher-ng/tunnelenable      boolean false" | sudo debconf-set-selections

		# This handles the wanted list in $hostdeps, updates apt only if needed
		install_host_side_packages "$hostdeps"

		update-ccache-symlinks

		export FINAL_HOST_DEPS="$hostdeps ${EXTRA_BUILD_DEPS}"
		call_extension_method "host_dependencies_ready" <<- 'HOST_DEPENDENCIES_READY'
			*run after all host dependencies are installed*
			At this point we can read `${FINAL_HOST_DEPS}`, but changing won't have any effect.
			All the dependencies, including the default/core deps and the ones added via `${EXTRA_BUILD_DEPS}`
			are installed at this point. The system clock has not yet been synced.
		HOST_DEPENDENCIES_READY

		# sync clock
		if [[ $SYNC_CLOCK != no ]]; then
			display_alert "Syncing clock" "host" "info"
			ntpdate -s "${NTP_SERVER:-pool.ntp.org}"
		fi

		# create directory structure
		mkdir -p "${SRC}"/{cache,output} "${USERPATCHES_PATH}"
		if [[ -n $SUDO_USER ]]; then
			chgrp --quiet sudo cache output "${USERPATCHES_PATH}"
			# SGID bit on cache/sources breaks kernel dpkg packaging
			chmod --quiet g+w,g+s output "${USERPATCHES_PATH}"
			# fix existing permissions
			find "${SRC}"/output "${USERPATCHES_PATH}" -type d ! -group sudo -exec chgrp --quiet sudo {} \;
			find "${SRC}"/output "${USERPATCHES_PATH}" -type d ! -perm -g+w,g+s -exec chmod --quiet g+w,g+s {} \;
		fi
		mkdir -p "${DEST}"/debs-beta/extra "${DEST}"/debs/extra "${DEST}"/{config,debug,patch} "${USERPATCHES_PATH}"/overlay "${SRC}"/cache/{sources,hash,hash-beta,toolchain,utility,rootfs} "${SRC}"/.tmp

		# build aarch64
		if [[ $(dpkg --print-architecture) == amd64 ]]; then
			if [[ "${SKIP_EXTERNAL_TOOLCHAINS}" != "yes" ]]; then

				# bind mount toolchain if defined
				if [[ -d "${ARMBIAN_CACHE_TOOLCHAIN_PATH}" ]]; then
					mountpoint -q "${SRC}"/cache/toolchain && umount -l "${SRC}"/cache/toolchain
					mount --bind "${ARMBIAN_CACHE_TOOLCHAIN_PATH}" "${SRC}"/cache/toolchain
				fi

				display_alert "Checking for external GCC compilers" "" "info"
				# download external Linaro compiler and missing special dependencies since they are needed for certain sources

				local toolchains=(
					"${ARMBIAN_MIRROR}/_toolchain/gcc-linaro-aarch64-none-elf-4.8-2013.11_linux.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-linaro-arm-none-eabi-4.8-2014.04_linux.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-linaro-arm-linux-gnueabihf-4.8-2014.04_linux.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabi.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchains/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchains/gcc-arm-8.3-2019.03-x86_64-aarch64-linux-gnu.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-arm-9.2-2019.12-x86_64-arm-none-linux-gnueabihf.tar.xz"
					"${ARMBIAN_MIRROR}/_toolchain/gcc-arm-9.2-2019.12-x86_64-aarch64-none-linux-gnu.tar.xz"
				)

				USE_TORRENT_STATUS=${USE_TORRENT}
				USE_TORRENT="no"
				for toolchain in ${toolchains[@]}; do
					download_and_verify "_toolchain" "${toolchain##*/}"
				done
				USE_TORRENT=${USE_TORRENT_STATUS}

				rm -rf "${SRC}"/cache/toolchain/*.tar.xz*
				local existing_dirs=($(ls -1 "${SRC}"/cache/toolchain))
				for dir in ${existing_dirs[@]}; do
					local found=no
					for toolchain in ${toolchains[@]}; do
						local filename=${toolchain##*/}
						local dirname=${filename//.tar.xz/}
						[[ $dir == $dirname ]] && found=yes
					done
					if [[ $found == no ]]; then
						display_alert "Removing obsolete toolchain" "$dir"
						rm -rf "${SRC}/cache/toolchain/${dir}"
					fi
				done
			else
				display_alert "Ignoring toolchains" "SKIP_EXTERNAL_TOOLCHAINS: ${SKIP_EXTERNAL_TOOLCHAINS}" "info"
			fi
		fi

	fi # check offline

	# enable arm binary format so that the cross-architecture chroot environment will work
	if [[ $KERNEL_ONLY != yes ]]; then
		modprobe -q binfmt_misc || display_alert "Failed to modprobe" "binfmt_misc" "warn"
		mountpoint -q /proc/sys/fs/binfmt_misc/ || mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
		if [[ "$(arch)" != "aarch64" ]]; then
			test -e /proc/sys/fs/binfmt_misc/qemu-arm || update-binfmts --enable qemu-arm
			test -e /proc/sys/fs/binfmt_misc/qemu-aarch64 || update-binfmts --enable qemu-aarch64
		fi
	fi

	[[ ! -f "${USERPATCHES_PATH}"/customize-image.sh ]] && cp "${SRC}"/config/templates/customize-image.sh.template "${USERPATCHES_PATH}"/customize-image.sh

	if [[ ! -f "${USERPATCHES_PATH}"/README ]]; then
		rm -f "${USERPATCHES_PATH}"/readme.txt
		echo 'Please read documentation about customizing build configuration' > "${USERPATCHES_PATH}"/README
		echo 'https://www.armbian.com/using-armbian-tools/' >> "${USERPATCHES_PATH}"/README

		# create patches directory structure under USERPATCHES_PATH
		find "${SRC}"/patch -maxdepth 2 -type d ! -name . | sed "s%/.*patch%/$USERPATCHES_PATH%" | xargs mkdir -p
	fi

	# check free space (basic)
	local freespace=$(findmnt --target "${SRC}" -n -o AVAIL -b 2> /dev/null) # in bytes
	if [[ -n $freespace && $(($freespace / 1073741824)) -lt 10 ]]; then
		display_alert "Low free space left" "$(($freespace / 1073741824)) GiB" "wrn"
		# pause here since dialog-based menu will hide this message otherwise
		echo -e "Press \e[0;33m<Ctrl-C>\x1B[0m to abort compilation, \e[0;33m<Enter>\x1B[0m to ignore and continue"
		read
	fi
}

# wait_for_package_manager
#
# * installation will break if we try to install when package manager is running
#
wait_for_package_manager() {
	# exit if package manager is running in the back
	while true; do
		if [[ "$(
			fuser /var/lib/dpkg/lock 2> /dev/null
			echo $?
		)" != 1 && "$(
			fuser /var/lib/dpkg/lock-frontend 2> /dev/null
			echo $?
		)" != 1 ]]; then
			display_alert "Package manager is running in the background." "Please wait! Retrying in 30 sec" "wrn"
			sleep 30
		else
			break
		fi
	done
}

function fetch_and_build_host_tools() {
	call_extension_method "fetch_sources_tools" <<- 'FETCH_SOURCES_TOOLS'
		*fetch host-side sources needed for tools and build*
		Run early to fetch_from_repo or otherwise obtain sources for needed tools.
	FETCH_SOURCES_TOOLS

	call_extension_method "build_host_tools" <<- 'BUILD_HOST_TOOLS'
		*build needed tools for the build, host-side*
		After sources are fetched, build host-side tools needed for the build.
	BUILD_HOST_TOOLS

}

# Install the whitespace-delimited packages listed in the first parameter, in the host (not chroot).
# It handles correctly the case where all wanted packages are already installed, and in that case does nothing.
# If packages are to be installed, it does an apt-get update first.
function install_host_side_packages() {
	declare wanted_packages_string
	declare -a currently_installed_packages missing_packages
	wanted_packages_string=${*}
	missing_packages=()
	# shellcheck disable=SC2207 # I wanna split, thanks.
	currently_installed_packages=($(dpkg-query --show --showformat='${Package} '))
	for PKG_TO_INSTALL in ${wanted_packages_string}; do
		# shellcheck disable=SC2076 # I wanna match literally, thanks.
		if [[ ! " ${currently_installed_packages[*]} " =~ " ${PKG_TO_INSTALL} " ]]; then
			display_alert "Should install package" "${PKG_TO_INSTALL}"
			missing_packages+=("${PKG_TO_INSTALL}")
		fi
	done

	if [[ ${#missing_packages[@]} -gt 0 ]]; then
		display_alert "Updating apt host-side for installing packages" "${#missing_packages[@]} packages" "info"
		host_apt_get update
		display_alert "Installing host-side packages" "${missing_packages[*]}" "info"
		host_apt_get_install "${missing_packages[@]}"
	else
		display_alert "All host-side dependencies/packages already installed." "Skipping host-hide install" "debug"
	fi

	unset currently_installed_packages
	return 0
}
