#!/bin/bash
#
# setup_linux: installs the computer system course home environment on Linux
#
# This script only officially supports Ubuntu 16.04, Debian 9,
# and Arch Linux; however, you should be able to run it on
# other distributions without much problem. If your package
# manager is not supported, you may have to manually install
# any required dependencies.
#
# Note that this script should NOT be run as root/sudo.
set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share_dir="${script_dir}/computer_system_course_share"
work_dir="${share_dir}/work"
qemu_dir="${script_dir}/qemu"
image_dir="${script_dir}/image"
vm_dir="${work_dir}/vm"
kernel_path="${work_dir}/source/linux-2.6.22.5/bzImage"

check_environment() {
    if [ "$EUID" -eq 0 ]; then
        echo "[-] Do not run this script as root/sudo!"
        exit 1
    fi

    if [ ! -f "${image_dir}/computer_system_course.qcow" ]; then
        echo "[-] Required files not found, move this script to the right location!"
        exit 1
    fi
}

install_deps() {
    echo "[*] Installing dependencies"

    # Ubuntu 16.04 + Debian 9
    command -v apt-get &>/dev/null \
        && sudo apt-get update \
        && sudo apt-get -y install \
            samba git curl perl libglib2.0-dev libfdt-dev libpixman-1-dev \
            zlib1g-dev libsdl1.2-dev libgtk2.0-dev \
        && return 0

    # Arch Linux
    command -v pacman &>/dev/null \
        && sudo pacman -Syu \
        && sudo pacman --needed --noconfirm -S \
            base base-devel samba git curl perl python2 \
            glib2 dtc pixman zlib sdl gtk2 \
        && return 0

    echo "[!] Unsupported package manager/distro/setup (or no network connection)"
    echo "[!] Please manually install: samba, curl, QEMU build dependencies"
    echo "[!] QEMU build info here: https://wiki.qemu.org/index.php/Hosts/Linux"
    echo "[!] When you are done, re-run this script to continue"
    read -r -p "[?] Have you installed the required dependencies? (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            echo "[*] Bypassing dependency check"
            ;;
        *)
            exit 1
            ;;
    esac
}

install_qemu() {
    if [ -f "${qemu_dir}/bin/qemu-system-i386" ]; then
        read -r -p "[?] QEMU already installed, do you want to re-install it? (y/N): " response
        case "$response" in
            [yY][eE][sS]|[yY])
                echo "[*] Re-installing QEMU"
                ;;
            *)
                echo "[*] Skipping QEMU re-install"
                return
                ;;
        esac
    else
        echo "[*] Installing QEMU"
    fi

    echo "[*] Removing existing QEMU files"
    rm -rf "${qemu_dir}"
    rm -rf "/tmp/qemu-1.5.0"
    rm -f "/tmp/qemu-1.5.0.tar.bz2"

    echo "[*] Downloading QEMU"
    curl -L "https://download.qemu.org/qemu-1.5.0.tar.bz2" -o "/tmp/qemu-1.5.0.tar.bz2"
    tar xfj "/tmp/qemu-1.5.0.tar.bz2" -C "/tmp"

    # Work around ancient QEMU bug
    # https://bugzilla.redhat.com/show_bug.cgi?id=969955
    echo "[*] Patching QEMU -- removing libfdt_env.h"
    rm "/tmp/qemu-1.5.0/include/libfdt_env.h"

    # Workaround for newer Perl versions
    echo "[*] Patching QEMU -- modifying texi2pod.pl"
    sed -i 's/@strong{(.*)}/@strong\\{$1\\}/g' "/tmp/qemu-1.5.0/scripts/texi2pod.pl"

    (
        # Need to cd into the directory or else make fails
        # Run this in a subshell so we return to our old directory after
        cd "/tmp/qemu-1.5.0"
        echo "[*] Compiling QEMU (this may take a few minutes)"

        # Another weird workaround
        export ARFLAGS="rv"

        # Only compile for i386 arch to speed up compile time
        # Output directory will be in ${qemu_dir}
        # Make sure we're using python2 for systems like Arch where python points to python3
        ./configure --target-list=i386-softmmu --prefix="${qemu_dir}" --python=python2
        make -j 4

        echo "[*] Installing QEMU"
        make install
    )
}

create_qcow() {
    echo "[*] Creating qcow files"
    mkdir -p "${vm_dir}"

    if [ ! -f "${vm_dir}/devel.qcow" ]; then
        echo "[*] Creating devel.qcow"
        "${qemu_dir}/bin/qemu-img" create -b "${image_dir}/computer_system_course.qcow" -f qcow2 "${vm_dir}/devel.qcow" >/dev/null
    fi

    if [ ! -f "${vm_dir}/test.qcow" ]; then
        echo "[*] Creating test.qcow"
        "${qemu_dir}/bin/qemu-img" create -b "${image_dir}/computer_system_course.qcow" -f qcow2 "${vm_dir}/test.qcow" >/dev/null
    fi
}

create_shortcuts() {
    echo "[*] Creating desktop shortcuts"
    mkdir -p ~/Desktop

    tee ~/Desktop/devel >/dev/null <<EOF
#!/bin/sh
"${qemu_dir}/bin/qemu-system-i386" -hda "${vm_dir}/devel.qcow" -m 512 -name devel
EOF

    tee ~/Desktop/test_debug >/dev/null <<EOF
#!/bin/sh
"${qemu_dir}/bin/qemu-system-i386" -hda "${vm_dir}/test.qcow" -m 512 -name test -gdb tcp:127.0.0.1:1234 -kernel "${kernel_path}" -S
EOF

    tee ~/Desktop/test_nodebug >/dev/null <<EOF
#!/bin/sh
"${qemu_dir}/bin/qemu-system-i386" -hda "${vm_dir}/test.qcow" -m 512 -name test -gdb tcp:127.0.0.1:1234 -kernel "${kernel_path}"
EOF

    echo "[*] Making desktop shortcuts executable"
    chmod a+x ~/Desktop/devel ~/Desktop/test_debug ~/Desktop/test_nodebug

    # This will fail on distros that don't use Nautilus,
    # so swallow any errors that occur.
    gsettings set org.gnome.nautilus.preferences executable-text-activation launch &>/dev/null || true
}

config_samba() {
    echo "[*] Setting up Samba"

    # Ensure Samba config exists
    if [ ! -f "/etc/samba/smb.conf" ]; then
        if [ -f "/etc/samba/smb.conf.default" ]; then
            echo "[*] Copying smb.conf from smb.conf.default"
            sudo cp "/etc/samba/smb.conf.default" "/etc/samba/smb.conf"
        else
            echo "[*] Downloading default Samba config file"
            curl "https://git.samba.org/samba.git/?p=samba.git;a=blob_plain;f=examples/smb.conf.default;hb=HEAD" -o "/tmp/smb.conf.default"
            sudo cp "/tmp/smb.conf.default" "/etc/samba/smb.conf"
        fi
    fi

    # Username must be same as Linux username for some reason
    echo "[*] Creating Samba user"
    smb_user=$(whoami)
    cat <<EOF
#############################################################
# Your Samba username is: ${smb_user}
# You will now be asked set up your Samba password
# This will be used to mount /workdir in the VM
#############################################################
EOF
    while :; do
        sudo smbpasswd -a "${smb_user}" && break
    done

    echo "[*] Removing old Samba config"
    sudo sed -i '/### BEGIN computer_system_course CONFIG ###/,/### END computer_system_course CONFIG ###/d' "/etc/samba/smb.conf" &>/dev/null

    echo "[*] Adding new Samba config"
    sudo tee -a "/etc/samba/smb.conf" >/dev/null <<EOF
### BEGIN computer_system_course CONFIG ###
[computer_system_course_share]
  path = "${share_dir}"
  valid users = ${smb_user}
  create mask = 0755
  read only = no

[global]
  ntlm auth = yes
### END computer_system_course CONFIG ###
EOF

    echo "[*] Configuring Samba service to run on boot"
    sudo systemctl enable smbd 2>/dev/null || sudo update-rc.d smbd defaults 2>/dev/null

    echo "[*] Restarting Samba service"
    sudo systemctl restart smbd 2>/dev/null || sudo service smbd restart 2>/dev/null
}

config_tux() {
    echo "[*] Creating udev rules for Tux controller"
    sudo tee "/etc/udev/rules.d/99-tux.rules" >/dev/null <<EOF
SUBSYSTEM=="tty", ATTRS{serial}=="computer_system_course", MODE="666"
EOF

    echo "[*] Reloading udev rules"
    sudo udevadm control --reload-rules
}

echo "[*] computer system course home setup script for Linux"
check_environment
install_deps
install_qemu
create_qcow
create_shortcuts
config_samba
config_tux
echo "[+] Done!"
