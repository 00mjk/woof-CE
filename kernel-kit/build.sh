#!/bin/bash
# originally by Iguleder - hacked to DEATH by 01micko
# see README
# Compile fatdog style kernel [v3+ - 3.10+ recommended].

. ./build.conf || exit 1

CWD=`pwd`
WGET_OPT='--no-check-certificate -q --show-progress'

for i in $@ ; do
	case $i in
		clean) DO_CLEAN=1 ; break ;;
	esac
done

if [ $DO_CLEAN ] ; then
	echo -en "\033[1;35m""WARNING\033[0m" #purple?
	echo " This will delete all builds and sources but wont touch configs."
	echo "Hit CTRL+C and save your stuff manually if you don't want to clean."
	echo "Hit ENTER to clean"
	read clean
	echo "Please wait..."
	rm -rf ./{dist,aufs*,kernel*,build.log*,linux-*}
	echo "Cleaning complete"
	exit 0
fi

if [ -d ./dist ] ; then
	echo "This is not a clean kit. Hit ENTER to continue"
	echo "or CTRL+C to quit and run './build.sh clean'"
	read notcleango
fi

## Dependency check...
for app in git gcc make ; do
	if ! $app --version &>/dev/null ; then
		echo -e "\033[1;31m""$app is not installed""\033[0m" && exit 1 #red
	fi
done
if ! which mksquashfs &>/dev/null ; then
	echo -e "\033[1;30m""mksquashfs is not installed but you can continue"
fi
echo -e "\033[0m" #reset to original

## determine number of jobs for make
if [ ! "$JOBS" ] ; then
	JOBS=$(grep "^processor" /proc/cpuinfo | wc -l)
	if [ $JOBS -ge 1 ] ; then
		JOBS="-j${JOBS}"
	else
		JOBS=""
	fi
fi
echo "Jobs for make: ${JOBS#-j}" ; echo

#------------------------------------------------------------------

if [ "$DOTconfig_file" -a ! -f "$DOTconfig_file" ] ; then
	echo "File not found: $DOTconfig_file (see build.conf - DOTconfig_file=)"
	exit 1
fi

if [ -f "$DOTconfig_file" ] ; then
	CONFIGS_DIR=${DOTconfig_file%/*} #dirname  $DOTconfig_file
	Choice=${DOTconfig_file##*/}     #basename $DOTconfig_file
	[ "$CONFIGS_DIR" = "$Choice" ] && CONFIGS_DIR=.
else
	## .configs
	[ -f /tmp/kernel_configs ] && rm -f /tmp/kernel_configs
	## CONFIG_DIR
	config_dirs='x86 x86_64 arm'
	case $(uname -m) in
		i?86)   cdefault=1 ; OS_ARCH=x86 ;;
		x86_64) cdefault=2 ; OS_ARCH=$(uname -m) ;;
		arm)    cdefault=3 ; OS_ARCH=$(uname -m) ;;
		*)      cdefault=1 ;;
	esac
	echo "Select architecture: "
	x=1
	for cdir in ${config_dirs} ; do
		if [ $x -eq $cdefault ] ; then
			echo "${x}. $cdir [default]"
		else
			echo "${x}. $cdir"
		fi
		let x++
	done
	echo -n "Enter option: " ; read copt
	case ${copt} in
		1|2|3|4) cchosen=${copt} ;;
		*) cchosen=${cdefault} ;;
	esac
	cdir=$(echo "$config_dirs" | cut -d ' ' -f ${cchosen})

	if [ "$cdir" != "$OS_ARCH" ] ; then
		echo "- Currently it's not possible to cross compile... sorry"
		exit 1
	fi

	CONFIGS_DIR=configs_${cdir}
	CONFIGS=$(ls ./${CONFIGS_DIR}/DOTconfig* 2>/dev/null | sed 's|.*/||' | sort -n)
	## list
	echo
	echo "Select the config file you want to use"
	NUM=1
	for C in $CONFIGS ;do
		echo "${NUM}. $C" >> /tmp/kernel_configs
		NUM=$(($NUM + 1))
	done
	echo "n. New DOTconfig" >> /tmp/kernel_configs
	if [ -f DOTconfig ] ; then
		echo "d. Default - current DOTconfig (./DOTconfig)" >> /tmp/kernel_configs
	fi
	cat /tmp/kernel_configs
	echo -n "Enter choice: " ; read Chosen
	if [ ! "$Chosen" -a ! -f DOTconfig ] ; then
		echo -e "\033[1;31m""ERROR: invalid choice, start again!""\033[0m"
		exit 1
	fi
	if [ "$Chosen" ] ; then
		Choice=$(grep "^$Chosen\." /tmp/kernel_configs | cut -d ' ' -f2)
		if [ ! "$Choice" ] ; then
			echo -e "\033[1;31m""ERROR: your choice is not sane ..quiting""\033[0m"
			exit 1
		fi 
	else
		Choice=Default
	fi
	echo -en "\nYou chose $Choice. 
If this is ok hit ENTER, if not hit CTRL|C to quit: " 
	read oknow
fi

case $Choice in
	Default)
		kver=$(grep 'kernel_version=' DOTconfig | head -1 | tr -s ' ' | cut -d '=' -f2)
		if [ "$kver" = "" ] ; then
			if [ "$kernel_ver" = "" ] ; then
				echo -n "Enter kernel version for DOTconfig: "
				read kernel_version
				[ ! $kernel_version ] && echo "ERROR" && exit 1
				echo "kernel_version=${kernel_version}" >> DOTconfig
			else
				kernel_version=${kernel_ver} #build.conf
			fi
		fi
		;;
	New)
		rm -f DOTconfig
		echo -n "Enter kernel version (ex: 3.14.73) : "
		read kernel_version
		;;
	*)
		case "$Choice" in DOTconfig-*)
			IFS=- read dconf kernel_version kernel_version_info <<< ${CONFIGS_DIR}/$Choice ;;
			*) kernel_version="" ;;
		esac
		if [ ! "$kernel_version" ] ; then
			kver=$(grep 'kernel_version=' ${CONFIGS_DIR}/$Choice | head -1 | tr -s ' ' | cut -d '=' -f2)
			sed -i '/^kernel_version/d' ${CONFIGS_DIR}/$Choice
			kernel_version=${kver}
			[ "$kernel_ver" ] && kernel_version=${kernel_ver} #build.conf
			echo "kernel_version=${kernel_version}" >> DOTconfig
			echo "kernel_version_info=${kernel_version_info}" >> DOTconfig
		fi
		if [ "${CONFIGS_DIR}/$Choice" != "./DOTconfig" ] ; then
			cp -afv ${CONFIGS_DIR}/$Choice DOTconfig
		fi
		[ ! "$package_name_suffix" ] && package_name_suffix=${kinfo}
		;;
esac

echo "kernel_version=${kernel_version}"
echo "kernel_version_info=${kernel_version_info}"
case "$kernel_version" in
	3.*|4.*) ok=1 ;; #----
	*) echo "ERROR: Unsupported kernel version" ; exit 1 ;;
esac

if [ "$Choice" != "New" -a ! -f DOTconfig ] ; then
	echo -e "\033[1;31m""ERROR: No DOTconfig found ..quiting""\033[0m"
	exit 1
fi

#------------------------------------------------------------------
FW_URL=${FW_URL:-http://distro.ibiblio.org/puppylinux/firmware}
# $package_name_suffix $custom_suffix $kernel_ver
kernel_version_full=${kernel_version}${custom_suffix}
kernel_srcsfs_version=${kernel_version}
aufs_utils_git="git://git.code.sf.net/p/aufs/aufs-util.git"
aufs_git_3="git://git.code.sf.net/p/aufs/aufs3-standalone.git"
aufs_git_4="git://github.com/sfjro/aufs4-standalone.git"
[ ! "$kernel_mirrors" ] && kernel_mirrors="ftp://www.kernel.org/pub/linux/kernel"
ksubdir_3=v3.x #http://www.kernel.org/pub/linux/kernel/v3.x
ksubdir_4=v4.x
#-- random kernel mirror first
rn=$(( ( RANDOM % $(echo "$kernel_mirrors" | wc -l) )  + 1 ))
x=0
for i in $kernel_mirrors ; do
	x=$((x+1))
	[ $x -eq $rn ] && first="$i" && continue
	km="$km $i"
done
kernel_mirrors="$first $km"
#--

if [ -f /etc/DISTRO_SPECS ] ; then
	. /etc/DISTRO_SPECS
	[ ! "$package_name_suffix" ] && package_name_suffix=${DISTRO_FILE_PREFIX}
fi

if [ -f DOTconfig ] ; then
	echo ; tail -n10 README ; echo
	for i in CONFIG_AUFS_FS=y CONFIG_NLS_CODEPAGE_850=y ; do
		if grep -q "$i" DOTconfig ; then
			echo "$i is ok"
		else
			echo -e "\033[1;31m""\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!   WARNING     !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n""\033[0m"
			if [ "$i" = "CONFIG_AUFS_FS=y" ] ; then
				echo "For your kernel to boot AUFS as a built in is required:"
				fs_msg="File systems -> Miscellaneous filesystems -> AUFS"
			else
				echo "For NLS to work at boot some configs are required:"
				fs_msg="NLS Support"
			fi
			echo "$i"
			echo "$i"|grep -q "CONFIG_NLS_CODEPAGE_850=y" && echo "CONFIG_NLS_CODEPAGE_852=y"
			echo "Make sure you enable this when you are given the opportunity after
	the kernel has downloaded and been patched.
	Look under ' $fs_msg'
	"
			echo -n "PRESS ENTER" ; read zzz
		fi
	done
fi

## fail-safe switch in case someone clicks the script in ROX (real story! not fun at all!!!!) :p
echo
read -p "Press ENTER to begin" dummy

#------------------------------------------------------------------

## version info
IFS=. read -r kernel_series \
		kernel_major_version \
		kernel_minor_version \
		kernel_minor_revision <<< "${kernel_version}"
kernel_branch=${kernel_major_version} #3.x 4.x kernels
kernel_major_version=${kernel_series}.${kernel_major_version} #crazy!! 3.14 2.6 etc
aufs_version=${kernel_series} ## aufs major version
[ "$kernel_minor_revision" ] && kmr=.${kernel_minor_revision}
echo "Linux: ${kernel_major_version}.${kernel_minor_version}${kmr}" #${kernel_series}.

if [ ! $aufsv ] ; then
	AUFS_BRANCHES='aufs3.0 aufs3.1 aufs3.11 aufs3.13 aufs3.15 aufs3.16 aufs3.17 aufs3.19 aufs3.3 aufs3.4 aufs3.5 aufs3.6 aufs3.7 aufs3.8 aufs3.9 aufs4.0 aufs4.2 aufs4.3 aufs4.4 aufs4.5 aufs4.6 aufs4.7 aufs4.8'
	if ( echo "$AUFS_BRANCHES" | tr ' ' '\n' | grep -q "^aufs${kernel_major_version}$" ) ; then
		aufsv=${kernel_major_version}
	### special cases ###
	elif [ "${kernel_major_version}" = "3.2" ] ; then
		aufsv='3.2'                #unknown actual value
		vercmp ${kernel_version} ge 3.2.30 && aufsv='3.2.x'
	elif [ "${kernel_major_version}" = "3.10" ] ; then
		aufsv='3.10'
		vercmp ${kernel_version} ge 3.10.26 && aufsv='3.10.x'
	elif [ "${kernel_major_version}" = "3.12" ] ; then
		aufsv='3.12'
		vercmp ${kernel_version} ge 3.12.7 && aufsv='3.12.x'
		vercmp ${kernel_version} ge 3.12.31 && aufsv='3.12.31+'
	elif [ "${kernel_major_version}" = "3.14" ] ; then
		aufsv='3.14'
		vercmp ${kernel_version} ge 3.14.21 && aufsv='3.14.21+'
		vercmp ${kernel_version} ge 3.14.40 && aufsv='3.14.40+'
	elif [ "${kernel_major_version}" = "3.18" ] ; then
		aufsv='3.18'
		vercmp ${kernel_version} ge 3.18.1 && aufsv='3.18.1+'
		vercmp ${kernel_version} ge 3.18.25 && aufsv='3.18.25+'
	elif [ "${kernel_major_version}" = "4.1" ] ; then
		aufsv='4.1'
		vercmp ${kernel_version} ge 4.1.13 && aufsv='4.1.13+'
	fi
fi

[ $aufsv ] || { echo "You must specify 'aufsv=version' in build.conf" ; exit 1 ; }
echo "aufs=$aufsv"

#kernel mirror - Aufs series (must match the kernel version)
case $kernel_series in
	3) ksubdir=${ksubdir_3} ; aufs_git=${aufs_git_3} ;;
	4) ksubdir=${ksubdir_4} ; aufs_git=${aufs_git_4} ;;
esac

#------------------------------------------------------------------

## create directories for the results
rm -rf dist/sources/patches
[ ! -d dist/sources/vanilla ] && mkdir -p dist/sources/vanilla
[ ! -d dist/sources/patches ] && mkdir -p dist/sources/patches
[ ! -d dist/packages ] && mkdir -p dist/packages

## get today's date
today=`date +%d%m%y`

## delete the previous log
[ -f build.log ] && rm -f build.log
[ -f build.log.tar.bz2 ] && mv -f build.log.${today}.tar.bz2

## download the kernel
testing=
echo ${kernel_version##*-} | grep -q "rc" && testing=testing

DOWNLOAD_KERNEL=1
if [ -f dist/sources/vanilla/linux-${kernel_version}.tar.* ] ; then
	echo "Verifying kernel pkg integrity..."
	tar -atf dist/sources/vanilla/linux-${kernel_version}.tar.* &>/dev/null && DOWNLOAD_KERNEL=0
fi

if [ $DOWNLOAD_KERNEL -eq 1 ] ; then
	KERROR=1
	for kernel_mirror in $kernel_mirrors ; do
		kernel_mirror=${kernel_mirror}/${ksubdir}
		echo "Downloading: ${kernel_mirror}/${testing}/linux-${kernel_version}.tar.xz"
		wget ${WGET_OPT} -P dist/sources/vanilla ${kernel_mirror}/${testing}/linux-${kernel_version}.tar.xz > build.log
		if [ $? -ne 0 ] ; then
			echo "Error"
		else
			KERROR=
			break
		fi
	done
	if [ $KERROR ] ; then
		rm -f dist/sources/vanilla/linux-${kernel_version}.tar.*
		exit 1
	fi
fi

## download Linux-libre scripts
if [ $LIBRE -eq 1 ] ; then
	minor_version=${kernel_version##*.}
	for i in deblob-${kernel_major_version} deblob-check; do
		if [ ! -f dist/sources/vanilla/$i ] ; then
			wget ${WGET_OPT} -O dist/sources/vanilla/$i http://linux-libre.fsfla.org/pub/linux-libre/releases/LATEST-${kernel_major_version}.N/$i
			if [ $? -ne 0 ] ; then
				echo "Error: failed to download $i."
				exit 1
			fi
		fi
	done
fi

## download Aufs
if [ -f dist/sources/vanilla/aufs${aufs_version}-${kernel_branch}-git${today}.tar.bz2 ] ; then
	echo "Extracting the Aufs sources"
	tar xf dist/sources/vanilla/aufs${aufs_version}-${kernel_branch}-git${today}.tar.bz2 >> build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Error: failed to extract the Aufs sources."
		exit 1
	fi
else
	echo "Downloading the Aufs sources"
	rm -rf aufs${aufs_version}-${kernel_branch}-git${today}
	git clone -b aufs${aufsv} --depth 1 ${aufs_git} \
		aufs${aufs_version}-${kernel_branch}-git${today} >> build.log 2>&1
	if [ $? -ne 0 ] ; then
		rm -f dist/sources/vanilla/aufs${aufs_version}-${kernel_branch}-git${today}.tar.bz2
		echo "Error: failed to download the Aufs sources."
		exit 1
	fi
	( cd aufs${aufs_version}-${kernel_branch}-git${today} ; rm -rf .git )
	echo "Creating the Aufs sources tarball"
	tar -c aufs${aufs_version}-${kernel_branch}-git${today} | \
		bzip2 -9 > dist/sources/vanilla/aufs${aufs_version}-${kernel_branch}-git${today}.tar.bz2
fi

## patch Aufs
if [ -f aufs-allow-sfs.patch ] ; then #removed for K3.9 experiment
	echo "Patching the Aufs sources" | tee -a build.log
	patch -d aufs${aufs_version}-${kernel_branch}-git${today} -p1 < aufs-allow-sfs.patch >> build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Error: failed to patch the Aufs sources."  | tee -a build.log
		exit 1
	fi
	cp aufs-allow-sfs.patch dist/sources/patches
fi
if [ -f aufs-kconfig.patch ] ; then #special for K3.9
	echo "Patching the Aufs sources" | tee -a build.log
	patch -d aufs${aufs_version}-${kernel_branch}-git${today} -p1 < aufs-kconfig.patch >> build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Error: failed to patch the Aufs sources for kconfig." | tee -a build.log
		exit 1
	fi
	cp aufs-kconfig.patch dist/sources/patches
fi

## extract the kernel
echo "Extracting the kernel sources"
tar xf dist/sources/vanilla/linux-${kernel_version}.tar.* >> build.log 2>&1
if [ $? -ne 0 ] ; then
	echo "Error: failed to extract the kernel sources."
	exit 1
fi

#-------------------------
cd linux-${kernel_version}
#-------------------------

echo "Adding Aufs to the kernel sources" | tee -a ../build.log
## hack - Aufs adds this file in the mmap patch, but it may be already there
if [ -f mm/prfile.c ] ; then
	mmap=../aufs${aufs_version}-${kernel_branch}-git${today}/aufs${aufs_version}-mmap.patch
	[ -f $mmap ] && grep -q 'mm/prfile.c' $mmap && rm -f mm/prfile.c #delete or mmap patch will fail
fi
for i in kbuild base standalone mmap; do #loopback tmpfs-idr vfs-ino
	patchfile=../aufs${aufs_version}-${kernel_branch}-git${today}/aufs${aufs_version}-$i.patch
	( echo ; echo "patch -N -p1 < ${patchfile##*/}" ) &>> ../build.log
	patch -N -p1 < ${patchfile} &>> ../build.log
	if [ $? -ne 0 ] ; then
		echo "WARNING: failed to add some Aufs patches to the kernel sources."
		echo "Check it manually and either CRTL+C to bail or hit enter to go on"
		read goon
	fi
done
cp -r ../aufs${aufs_version}-${kernel_branch}-git${today}/{fs,Documentation} .
cp ../aufs${aufs_version}-${kernel_branch}-git${today}/include/linux/aufs_type.h include/linux 2>/dev/null
cp ../aufs${aufs_version}-${kernel_branch}-git${today}/include/uapi/linux/aufs_type.h include/linux 2>/dev/null
[ -d ../aufs${aufs_version}-${kernel_branch}-git${today}/include/uapi ] && \
	cp -r ../aufs${aufs_version}-${kernel_branch}-git${today}/include/uapi/linux/aufs_type.h include/uapi/linux
#cat ../aufs${aufs_version}-1-git${today}/include/linux/Kbuild >> include/Kbuild
################################################################################

## deblob the kernel
if [ $LIBRE -eq 1 ] ; then
	cd ..
	cp -r linux-${kernel_version} linux-${kernel_version}-orig
	cd linux-${kernel_version}
	sh ../dist/sources/vanilla/deblob-${kernel_major_version} 2>&1 | tee -a ../build.log
	cd ..
	diff -rupN linux-${kernel_version}-orig linux-${kernel_version} > dist/sources/patches/deblob.patch
	rm -rf linux-${kernel_version}-orig
	cd linux-${kernel_version}
fi

## reset sublevel
cp Makefile Makefile-orig
if [ "$remove_sublevel" = "yes" ] ; then
	echo "Resetting the minor version number" #!
	sed -i "s/^SUBLEVEL =.*/SUBLEVEL = 0/" Makefile
	kernel_srcsfs_version=${kernel_major_version}.0
fi
## custom suffix
if [ -n "${custom_suffix}" ] || [ $LIBRE -eq 1 ] ; then
	sed -i "s/^EXTRAVERSION =.*/EXTRAVERSION = ${custom_suffix}/" Makefile
fi
diff -up Makefile-orig Makefile > ../dist/sources/patches/version.patch
rm Makefile-orig

echo "Reducing the number of consoles"
if [ $kernel_series -gt 3 ] || [ $kernel_series -eq 3 -a $kernel_branch -ge 12 ] ; then
	if [ $kernel_series -gt 3 ] || [ $kernel_series -eq 3 -a $kernel_branch -ge 16 ] ; then
		echo "Reducing the verbosity level"
		cp -f include/linux/printk.h include/linux/printk.h.orig
		sed -i s/'#define CONSOLE_LOGLEVEL_DEFAULT 7 \/\* anything MORE serious than KERN_DEBUG \*\/'/'#define CONSOLE_LOGLEVEL_DEFAULT 3 \/\* anything MORE serious than KERN_ERR \*\/'/ include/linux/printk.h
		diff -up include/linux/printk.h.orig include/linux/printk.h > ../dist/sources/patches/lower-verbosity.patch
	else
		cp kernel/printk/printk.c kernel/printk/printk.c.orig
		sed -i s/'#define MAX_CMDLINECONSOLES 8'/'#define MAX_CMDLINECONSOLES 5'/ kernel/printk/printk.c
		diff -up kernel/printk/printk.c.orig kernel/printk/printk.c > ../dist/sources/patches/less-consoles.patch
		echo "Reducing the verbosity level"
		cp -f kernel/printk/printk.c kernel/printk/printk.c.orig
		sed -i s/'#define DEFAULT_CONSOLE_LOGLEVEL 7 \/\* anything MORE serious than KERN_DEBUG \*\/'/'#define DEFAULT_CONSOLE_LOGLEVEL 3 \/\* anything MORE serious than KERN_ERR \*\/'/ kernel/printk/printk.c
		diff -up kernel/printk/printk.c.orig kernel/printk/printk.c > ../dist/sources/patches/lower-verbosity.patch
	fi
else
	cp kernel/printk.c kernel/printk.c.orig
	sed -i s/'#define MAX_CMDLINECONSOLES 8'/'#define MAX_CMDLINECONSOLES 5'/ kernel/printk.c
	diff -up kernel/printk.c.orig kernel/printk.c > ../dist/sources/patches/less-consoles.patch
	echo "Reducing the verbosity level"
	cp -f kernel/printk.c kernel/printk.c.orig
	sed -i s/'#define DEFAULT_CONSOLE_LOGLEVEL 7 \/\* anything MORE serious than KERN_DEBUG \*\/'/'#define DEFAULT_CONSOLE_LOGLEVEL 3 \/\* Puppy linux hack \*\/'/ kernel/printk.c
	diff -up kernel/printk.c.orig kernel/printk.c > ../dist/sources/patches/lower-verbosity.patch
fi

for patch in ../patches/* ; do
	echo "Applying $patch"
	patch -p1 < $patch >> ../build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Error: failed to apply $patch on the kernel sources."
		exit 1
	fi
	cp $patch ../dist/sources/patches
done

echo "Cleaning the kernel sources"
make clean
make mrproper
find . -name '*.orig' -delete
find . -name '*.rej' -delete
find . -name '*~' -delete

if [ -f ../DOTconfig ] ; then
	cp ../DOTconfig .config
	sed -i '/^kernel_version/d' .config
fi

## enable aufs in Kconfig
if [ -f fs/aufs/Kconfig ] ; then
	sed -i 's%support"$%support"\n\tdefault y%' fs/aufs/Kconfig
	sed -i 's%aufs branch"%aufs branch"\n\tdefault n%' fs/aufs/Kconfig
fi
if ! grep -q "CONFIG_AUFS_FS=y" .config ; then
	echo -e "\033[1;31m"
	echo "For your kernel to boot AUFS as a built in is required:"
	echo "File systems -> Miscellaneous filesystems -> AUFS" 
	echo -e "\033[0m" #reset to original
fi

#####################
# pause to configure
function do_kernel_config() {
	echo "make $1"
	make $1 ##
	if [ $? -eq 0 ] ; then
		if [ -f .config ] ; then
			echo -e "\nOk, kernel is configured. hit ENTER to continue, CTRL+C to quit"
			read goon
		fi
	else
		exit 1
	fi
	[ ! -f ../DOTconfig ] && cp .config ../DOTconfig
}

echo -en "
You now should configure your kernel. The supplied .config
should be already configured but you may want to make changes, plus
the date should be updated.

Hit a number or s to skip:
1. make menuconfig [default] (ncurses based)
2. make gconfig (gtk based gui)
3. make xconfig (qt based gui)
4. make oldconfig
s. skip

Enter option: " ; read kernelconfig
case $kernelconfig in
	1) do_kernel_config menuconfig ;;
	2) do_kernel_config gconfig    ;;
	3) do_kernel_config xconfig    ;;
	4) do_kernel_config oldconfig   ;;
	s)
		echo "skipping"
		echo "hit ENTER to continue, CTRL+C to quit"
		read goon
		;;
	*) do_kernel_config menuconfig ;;
esac

if [ ! -f .config ] ; then
	echo -e "\nNo config file, exiting..."
	exit 1
fi

#------------------------------------------------------------------

## kernel headers
kheaders_dir="kernel_headers-${kernel_version}-${package_name_suffix}"
rm -rf ../dist/packages/${kheaders_dir}
if [ ! -d ../dist/packages/${kheaders_dir} ] ; then
	echo "Creating the kernel headers package"
	make headers_check >> ../build.log 2>&1
	make INSTALL_HDR_PATH=${kheaders_dir}/usr headers_install >> ../build.log 2>&1
	find ${kheaders_dir}/usr/include \( -name .install -o -name ..install.cmd \) -delete
	mv ${kheaders_dir} ../dist/packages
fi

echo "Compiling the kernel" | tee -a ../build.log
make ${JOBS} bzImage modules >> ../build.log 2>&1
cp .config ../dist/sources/DOTconfig-${kernel_version}-${today}
CONFIG=../dist/sources/DOTconfig-${kernel_version}-${today}

## we need the arch of the system being built
if grep -q 'CONFIG_X86_64=y' ${CONFIG} ; then
	arch=x86_64
	karch=x86
elif grep -q 'CONFIG_X86_32=y' ${CONFIG} ; then
	if grep -q 'CONFIG_X86_32_SMP=y' ${CONFIG} ; then
		arch=i686
		karch=x86
	else
		arch=i486 #gross assumption
		karch=x86
	fi
elif grep -q 'CONFIG_ARM=y' ${CONFIG} ; then
	arch=arm
	karch=arm
else
	echo "Your arch is unsupported."
	arch=unknown #allow build anyway
	karch=arm
fi

if [ $karch == 'x86' ] ; then
	if [ ! -f arch/x86/boot/bzImage -o ! -f System.map ] ; then
		echo "Error: failed to compile the kernel sources."
		exit 1
	fi
else
	if [ ! -f arch/arm/boot/zImage ] ; then #needs work
		echo "Error: failed to compile the kernel sources."
		exit 1
	fi
fi

#.....................................................................
linux_kernel_dir=linux_kernel-${kernel_version}-${package_name_suffix}
#.....................................................................

#---------------------------------------------------------------------

echo "Creating the kernel package"
make INSTALL_MOD_PATH=${linux_kernel_dir} modules_install >> ../build.log 2>&1
rm -f ${linux_kernel_dir}/lib/modules/${kernel_srcsfs_version}${custom_suffix}/{build,source}
mkdir -p ${linux_kernel_dir}/boot
mkdir -p ${linux_kernel_dir}/etc/modules
## /boot/config-$(uname -m)     ## http://www.h-online.com/open/features/Good-and-quick-kernel-configuration-creation-1403046.html
cp .config ${linux_kernel_dir}/boot/config-${kernel_version_full}
## /boot/Sytem.map-$(uname -r)  ## https://en.wikipedia.org/wiki/System.map
cp System.map ${linux_kernel_dir}/boot/System.map-${kernel_version_full}
## /etc/moodules/..
cp .config ${linux_kernel_dir}/etc/modules/DOTconfig-${kernel_version}-${today}
cp ${linux_kernel_dir}/lib/modules/${kernel_srcsfs_version}${custom_suffix}/modules.builtin \
	${linux_kernel_dir}/etc/modules/modules.builtin-${kernel_version_full}
cp ${linux_kernel_dir}/lib/modules/${kernel_srcsfs_version}${custom_suffix}/modules.order \
	${linux_kernel_dir}/etc/modules/modules.order-${kernel_version_full}

#cp arch/x86/boot/bzImage ${linux_kernel_dir}/boot/vmlinuz
BZIMAGE=`find . -type f -name bzImage | head -1`
cp ${BZIMAGE} ${linux_kernel_dir}/boot
cp ${BZIMAGE} ${linux_kernel_dir}/boot/vmlinuz

mv ${linux_kernel_dir} ../dist/packages ## ../dist/packages/${linux_kernel_dir}

## make fatdog kernel module package
mv ../dist/packages/${linux_kernel_dir}/boot/vmlinuz \
	../dist/packages/vmlinuz-${kernel_version}-${package_name_suffix}
[ -f ../dist/packages/${linux_kernel_dir}/boot/bzImage ] && \
	rm -f ../dist/packages/${linux_kernel_dir}/boot/bzImage
echo "Huge kernel ${kernel_version}-${package_name_suffix} is ready in dist"

echo "Cleaning the kernel sources"
make clean >> ../build.log 2>&1
make prepare >> ../build.log 2>&1

#----
cd ..
#----

echo "Creating a kernel sources SFS"
mkdir -p kernel_sources-${kernel_version}-${package_name_suffix}/usr/src
mv linux-${kernel_version} kernel_sources-${kernel_version}-${package_name_suffix}/usr/src/linux
mkdir -p kernel_sources-${kernel_version}-${package_name_suffix}/lib/modules/${kernel_srcsfs_version}${custom_suffix}
ln -s /usr/src/linux kernel_sources-${kernel_version}-${package_name_suffix}/lib/modules/${kernel_srcsfs_version}${custom_suffix}/build
if [ ! -f kernel_sources-${kernel_version}-${package_name_suffix}/usr/src/linux/include/linux/version.h ] ; then
	ln -s /usr/src/linux/include/generated/uapi/linux/version.h \
		kernel_sources-${kernel_version}-${package_name_suffix}/usr/src/linux/include/linux/version.h
fi
ln -s /usr/src/linux kernel_sources-${kernel_version}-${package_name_suffix}/lib/modules/${kernel_srcsfs_version}${custom_suffix}/source
mksquashfs kernel_sources-${kernel_version}-${package_name_suffix} dist/sources/kernel_sources-${kernel_version}-${package_name_suffix}.sfs $COMP
md5sum dist/sources/kernel_sources-${kernel_version}-${package_name_suffix}.sfs > dist/sources/kernel_sources-${kernel_version}-${package_name_suffix}.sfs.md5.txt

####################################
# build aufs-utils userspace modules
echo "Now to build the aufs-utils for userspace"
if [ ! -f dist/sources/vanilla/aufs-util${today}.tar.bz2 ] ; then
	if [ ! -d aufs-util ] ; then
		git clone ${aufs_utils_git} aufs-util
		if [ $? -ne 0 ] ; then
			echo "Failed to get aufs-util from git, do it manually. Kernel is compiled OK :)"
			rm -rf aufs-util
			exit 1
		fi
	fi
	#-----------
	cd aufs-util
	#-----------
	git branch -a | grep "aufs$kernel_series" | \
		grep -v -E 'rcN|\)' | cut -d '.' -f2 | \
		sort -n > /tmp/aufs-util-version #we go for stable only
	while read line ; do 
		if [ "$line" -le "$kernel_branch" ] ; then #less or equal than $kernel_branch
			branch=$line
			echo $line
		else
			break
		fi
	done < /tmp/aufs-util-version
	git checkout origin/aufs${kernel_series}.${branch} >> ../build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Failed to get aufs-util from git, do it manually. Kernel is compiled OK :)"
		exit 1
	fi
	## patch Makefile for static build
	echo "Patching aufs-util sources"
	cp Makefile Makefile.orig
	sed -i 's/-static //' Makefile
	sed -i 's|ver_test ||' Makefile # ver_test might fail
	sed -i 's|BuildFHSM = .*||' Makefile
	diff -ru Makefile.orig Makefile > ../dist/sources/patches/aufs-util-dynamic.patch
	rm *.orig
else
	echo "Extracting the Aufs-util sources"
	tar xf dist/sources/vanilla/aufs-util${today}.tar.bz2 >> ../build.log 2>&1
	if [ $? -ne 0 ] ; then
		echo "Error: failed to extract the aufs-util sources."
		exit 1
	fi
	cd aufs-util
	patch -p1 < ../dist/sources/patches/aufs-util-dynamic.patch >> ../build.log 2>&1
	if [ "$?" -ne 0 ] ; then
		echo "Failed to patch the aufs-util sources, do it manually. Kernel is compiled ok"
		exit 1
	fi
fi

## see if fhsm is enabled in kernel config
if grep -q 'CONFIG_AUFS_FHSM=y' ${CONFIG} ; then
	export MAKE="make BuildFHSM=yes"
else
	export MAKE="make BuildFHSM=no"
fi
LinuxSrc=$(find $CWD -type d -name "kernel_headers*" | head -1)
export CPPFLAGS="-I $LinuxSrc/usr/include"

echo "export CPPFLAGS=\"-I $LinuxSrc/usr/include\"
make clean
$MAKE
make DESTDIR=$CWD/dist/packages/aufs-util-${kernel_version}-${arch} install
" > compile ## debug

make clean &>/dev/null
$MAKE >> ../build.log 2>&1
if [ $? -ne 0 ] ; then
	echo "Failed to compile aufs-util, do it manually. Kernel is compiled OK :)"
	exit 1
fi
make DESTDIR=$CWD/dist/packages/aufs-util-${kernel_version}-${arch} install >> ../build.log 2>&1 #needs absolute path

make clean >> ../build.log 2>&1
if [ "$arch" = "x86_64" ] ; then
	mv $CWD/dist/packages/aufs-util-${kernel_version}-${arch}/usr/lib \
		$CWD/dist/packages/aufs-util-${kernel_version}-${arch}/usr/lib64
fi
echo "aufs-util-${kernel_version} is in dist"

#----
cd ..
#----

echo "Installing aufs-utils into kernel package"
cp -a --remove-destination dist/packages/aufs-util-${kernel_version}-${arch}/* \
	dist/packages/${linux_kernel_dir}

if [ $LIBRE -eq 0 ] ; then
	echo "Pausing here to add extra firmware."
	echo "Choose an option:"
	## download the fw or offer to copy
	tmpfw=/tmp/fw$$
	x=1
	wget -q ${FW_URL} -O - | \
		sed '/href/!d; /\.tar\./!d; /md5\.txt/d; s/.*href="//; s/".*//' | \
		while read f;do
			[ "$f" ] && echo "$x $f" >> ${tmpfw}
			x=$(($x + 1 ))
		done
	y=`cat ${tmpfw} | wc -l `
	[ "$y" = 0 ] && echo "WARNING: no firmware at that URL" # we carry on
	x=$(($x + $y))
	echo "$x I'll copy in my own." >> ${tmpfw}
	x=$(($x + 1))
	echo "$x I'll grab the latest firmware from kernel.org. (slow)" >> ${tmpfw}
	cat ${tmpfw}
	echo -n "Enter a number, 1 to $x:  "
	read fw
	case $fw in
		[0-9]*) ok=1 ;;
		*)	echo "invalid option... falling back to option $(($x - 1))"
			fw=$(($x - 1))
			;;
	esac
	## if $fw is not a number then the conditionals below will fail
	if [ "$fw" -gt "$x" ] ; then
		echo "error, wrong number"
		exit 1
	elif [ "$fw" = "$(($x - 1))" ] ; then
		echo "once you have manually added firmware to "
		echo "dist/packages/${linux_kernel_dir}/lib/firmware"
		echo "hit ENTER to continue"
		read firm
	elif [ "$fw" = "$x" ] ; then
		## fw.sh - linux-firmware git ##
		echo "You have chosen to get the latest firmware from kernel.org"
		if [ -d ../linux-firmware ] ; then #outside kernel-kit
			echo "'git pull' will run so it wont take long to update the"
			echo "firmware repository"
		else
			echo "This may take a long time as the firmware repository is around 180MB"
		fi
		## run the firmware script and re-enter here
		./fw.sh ${fw_flag} # optonal param; see fw.sh and build.conf
		ret=$?
		if [ $ret -eq 0 ] ; then
			echo "Extracting firmware from the kernel.org git repo has succeeded."
		else
			echo "WARNING: Extracting firmware from the kernel.org git repo has failed."
			echo "While your kernel is built, your firmware is incomplete."
		fi
	else
		fw_pkg=`grep ^$fw ${tmpfw}`
		fw_pkg=${fw_pkg##* }
		echo "You chose ${fw_pkg}. If that isn't correct change it manually later."
		echo "downloading ${FW_URL}/${fw_pkg}"
		wget ${WGET_OPT} -t0 -c ${FW_URL}/${fw_pkg} -P dist/packages
		[ $? -ne 0 ] && echo "failed to download ${fw_pkg##* }" && exit 1
		mkdir -p dist/packages/${linux_kernel_dir}/lib
		tar -xjf dist/packages/${fw_pkg} -C dist/packages/${linux_kernel_dir}/lib/
		[ $? -ne 0 ] && echo "failed to unpack ${fw_pkg}" && exit 1
		echo "Successfully extracted ${fw_pkg}."
	fi
fi

mksquashfs dist/packages/${linux_kernel_dir} dist/packages/kernel-modules.sfs-${kernel_version}-${package_name_suffix} $COMP
[ $? = 0 ] || exit 1
echo "Huge compatible kernel packages are ready to package./"
echo "Packaging huge-${kernel_version}-${package_name_suffix} kernel"
cd dist/packages/
tar -cjvf huge-${kernel_version}-${package_name_suffix}.tar.bz2 \
	vmlinuz-${kernel_version}-${package_name_suffix} kernel-modules.sfs-${kernel_version}-${package_name_suffix}
	if [ "$?" = 0 ] ; then
		echo "huge-${kernel_version}-${package_name_suffix}.tar.bz2 is in dist/packages"
	else
		exit 1
	fi
md5sum huge-${kernel_version}-${package_name_suffix}.tar.bz2 > huge-${kernel_version}-${package_name_suffix}.tar.bz2.md5.txt
echo
cd -

tar -c aufs-util | bzip2 -9 > dist/sources/vanilla/aufs-util${today}-${arch}.tar.bz2

echo "Compressing the log"
bzip2 -9 build.log
cp build.log.bz2 dist/sources

echo "Done!"
#[ -f /usr/share/sounds/2barks.au ] && aplay /usr/share/sounds/2barks.au

### END ###
