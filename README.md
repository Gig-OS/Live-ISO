# Script dependencies

* bash
* wget
* tar
* xz
* git
* make
* rsync
* squashfs-tools with xz support
* asciidoc (build arch-install-script)

# Files

* build.sh: main script to build
* arch-scripts: arch-chroot scripts
* hooks: scripts to run after upgrade system
* include-squashfs: files that will copy to suqashfs before upgrade
* include-squashfs.after: files that will copy to suqashfs after upgrade

# Tips

change `TMPFS` suitable size for you in `build.sh` to speedup package building

modify `include-squashfs/etc/portage/make.conf/common` according to your needs
