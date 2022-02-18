#--------------------------------------------------------------------------------------------------------------------------------
# fingerprint_image <out_txt_file> [image_filename]
# Saving build summary to the image
#--------------------------------------------------------------------------------------------------------------------------------
fingerprint_image() {
	cat <<- EOF > "${1}"
		--------------------------------------------------------------------------------
		Title:          ${VENDOR} $REVISION ${BOARD^} $BRANCH
		Kernel:         Linux $VER
		Build date:     $(date +'%d.%m.%Y')
		Maintainer:     $MAINTAINER <$MAINTAINERMAIL>
		Authors:        https://www.armbian.com/authors
		Sources:        https://github.com/armbian/
		Support:        https://forum.armbian.com/
		Changelog:      https://www.armbian.com/logbook/
		Documantation:  https://docs.armbian.com/
	EOF

	if [ -n "$2" ]; then
		cat <<- EOF >> "${1}"
			--------------------------------------------------------------------------------
			Partitioning configuration: $IMAGE_PARTITION_TABLE offset: $OFFSET
			Boot partition type: ${BOOTFS_TYPE:-(none)} ${BOOTSIZE:+"(${BOOTSIZE} MB)"}
			Root partition type: $ROOTFS_TYPE ${FIXED_IMAGE_SIZE:+"(${FIXED_IMAGE_SIZE} MB)"}

			CPU configuration: $CPUMIN - $CPUMAX with $GOVERNOR
			--------------------------------------------------------------------------------
			Verify GPG signature:
			gpg --verify $2.img.asc

			Verify image file integrity:
			sha256sum --check $2.img.sha

			Prepare SD card (four methodes):
			zcat $2.img.gz | pv | dd of=/dev/mmcblkX bs=1M
			dd if=$2.img of=/dev/mmcblkX bs=1M
			balena-etcher $2.img.gz -d /dev/mmcblkX
			balena-etcher $2.img -d /dev/mmcblkX
		EOF
	fi

	cat <<- EOF >> "${1}"
		--------------------------------------------------------------------------------
		$(cat "${SRC}"/LICENSE)
		--------------------------------------------------------------------------------
	EOF
}