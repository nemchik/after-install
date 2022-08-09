#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# System Information
ARCH=$(uname -m)
readonly ARCH
export ARCH
DPKG_ARCH=$(dpkg --print-architecture)
readonly DPKG_ARCH
export DPKG_ARCH
ID=$(grep --color=never -Po '^ID=\K.*' /etc/os-release)
readonly ID
export ID
VERSION_CODENAME=$(grep --color=never -Po '^VERSION_CODENAME=\K.*' /etc/os-release)
readonly VERSION_CODENAME
export VERSION_CODENAME

# User/Group Information
readonly DETECTED_PUID=${SUDO_UID:-$UID}
export DETECTED_PUID
DETECTED_UNAME=$(id -un "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_UNAME
export DETECTED_UNAME
DETECTED_PGID=$(id -g "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_PGID
export DETECTED_PGID
DETECTED_UGROUP=$(id -gn "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_UGROUP
export DETECTED_UGROUP
DETECTED_HOMEDIR=$(eval echo "~${DETECTED_UNAME}" 2> /dev/null || true)
readonly DETECTED_HOMEDIR
export DETECTED_HOMEDIR

# Cleanup Function
cleanup() {
    local -ri EXIT_CODE=$?

    exit ${EXIT_CODE}
    trap - ERR EXIT SIGABRT SIGALRM SIGHUP SIGINT SIGQUIT SIGTERM
}
trap 'cleanup' ERR EXIT SIGABRT SIGALRM SIGHUP SIGINT SIGQUIT SIGTERM

# Check if running as root
check_root() {
    if [[ ${DETECTED_PUID} == "0" ]] || [[ ${DETECTED_HOMEDIR} == "/root" ]]; then
        echo "Running as root is not supported. Please run as a standard user with sudo."
        exit 1
    fi
}

# Check if running with sudo
check_sudo() {
    if [[ ${EUID} -eq 0 ]]; then
        echo "Running with sudo is not supported. Commands requiring sudo will prompt automatically when required."
        exit 1
    fi
}

# apt-get updates, installs, and cleanups
package_management() {
    sudo apt-get -y update
    sudo apt-get -y install \
        apt-transport-https \
        ca-certificates \
        curl \
        fonts-powerline \
        fuse \
        git \
        grep \
        htop \
        ncdu \
        rsync \
        sed \
        smartmontools \
        tmux
    sudo apt-get -y dist-upgrade
    sudo apt-get -y autoremove
    sudo apt-get -y autoclean
}

# Kernel modules for vpn
kernel_modules() {
    echo "iptable_mangle" | sudo tee /etc/modules-load.d/iptable_mangle.conf
    echo "tun" | sudo tee /etc/modules-load.d/tun.conf
}

# https://github.com/trapexit/mergerfs/releases
mergerfs_install() {
    local AVAILABLE_MERGERFS
    AVAILABLE_MERGERFS=$(curl -fsL "https://api.github.com/repos/trapexit/mergerfs/releases/latest" | grep -Po '"tag_name": "[Vv]?\K.*?(?=")')
    local MERGERFS_FILENAME="mergerfs_${AVAILABLE_MERGERFS}.${ID}-${VERSION_CODENAME}_${DPKG_ARCH}.deb"
    local MERGERFS_TMP
    MERGERFS_TMP=$(mktemp)
    curl -fsL "https://github.com/trapexit/mergerfs/releases/download/${AVAILABLE_MERGERFS}/${MERGERFS_FILENAME}" -o "${MERGERFS_TMP}"
    sudo dpkg -i "${MERGERFS_TMP}"
    rm -f "${MERGERFS_TMP}" || true
}

# https://help.ubuntu.com/community/StricterDefaults
stricter_defaults() {
    # https://help.ubuntu.com/community/StricterDefaults#Shared_Memory
    if ! grep -q '/run/shm' /etc/fstab; then
        echo "none     /run/shm     tmpfs     defaults,ro     0     0" | sudo tee -a /etc/fstab
    fi
    sudo mount -o remount /run/shm || true

    # https://help.ubuntu.com/community/StricterDefaults#Disable_Password_Authentication
    # only disable password authentication if an ssh key is found in the authorized_keys file
    # be sure to setup your ssh key before running this script
    # also be sure to use an ed25519 key (preferred) or an rsa key
    if grep -q -E '^(sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t|ssh-ed25519 AAAAC3NzaC1lZDI1NTE5|ssh-rsa AAAAB3NzaC1yc2E)[0-9A-Za-z+/]+[=]{0,3}(\s.*)?$' "${DETECTED_HOMEDIR}/.ssh/authorized_keys"; then
        sudo sed -i -E 's/^#?PasswordAuthentication .*$/PasswordAuthentication no/g' /etc/ssh/sshd_config
    fi

    # https://help.ubuntu.com/community/StricterDefaults#SSH_Root_Login
    sudo sed -i -E 's/^#?PermitRootLogin .*$/PermitRootLogin no/g' /etc/ssh/sshd_config

    # restart ssh after all the changes above
    sudo systemctl restart ssh
}

# auto-tmux for SSH logins
# https://github.com/spencertipping/bashrc-tmux
tmux_auto() {
    if [[ ! -d "${DETECTED_HOMEDIR}/bashrc-tmux" ]]; then
        git clone https://github.com/spencertipping/bashrc-tmux.git "${DETECTED_HOMEDIR}/bashrc-tmux"
    else
        git -C "${DETECTED_HOMEDIR}/bashrc-tmux" pull
        git -C "${DETECTED_HOMEDIR}/bashrc-tmux" fetch --all --prune
        git -C "${DETECTED_HOMEDIR}/bashrc-tmux" reset --hard origin/master
        git -C "${DETECTED_HOMEDIR}/bashrc-tmux" pull
    fi
    if ! grep -q 'bashrc-tmux' "${DETECTED_HOMEDIR}/.bashrc"; then
        local BASHRC_TMP
        BASHRC_TMP=$(mktemp)
        cat <<- 'EOF' | sed -E 's/^ *//' | cat - "${DETECTED_HOMEDIR}/.bashrc" > "${BASHRC_TMP}"
            [ -z "$PS1" ] && return                 # this still comes first
            source ~/bashrc-tmux/bashrc-tmux

            # rest of bashrc below...

EOF
        mv "${BASHRC_TMP}" "${DETECTED_HOMEDIR}/.bashrc"
        rm -f "${BASHRC_TMP}"
    fi
    chown -R "${DETECTED_PUID}":"${DETECTED_PGID}" "${DETECTED_HOMEDIR}/bashrc-tmux"
    chown -R "${DETECTED_PUID}":"${DETECTED_PGID}" "${DETECTED_HOMEDIR}/.bashrc"
}

# tmux config
# https://github.com/gpakosz/.tmux
tmux_config() {
    if [[ ! -d "${DETECTED_HOMEDIR}/.tmux" ]]; then
        git clone https://github.com/gpakosz/.tmux.git "${DETECTED_HOMEDIR}/.tmux"
    else
        git -C "${DETECTED_HOMEDIR}/.tmux" pull
        git -C "${DETECTED_HOMEDIR}/.tmux" fetch --all --prune
        git -C "${DETECTED_HOMEDIR}/.tmux" reset --hard origin/master
        git -C "${DETECTED_HOMEDIR}/.tmux" pull
    fi

    ln -s -f "${DETECTED_HOMEDIR}/.tmux/.tmux.conf" "${DETECTED_HOMEDIR}/.tmux.conf"
    cp -n "${DETECTED_HOMEDIR}/.tmux/.tmux.conf.local" "${DETECTED_HOMEDIR}/.tmux.conf.local"
    sudo sed -i -E 's/^#?set -g mouse on$/set -g mouse on/g' "${DETECTED_HOMEDIR}/.tmux.conf.local"
    chown -R "${DETECTED_PUID}":"${DETECTED_PGID}" "${DETECTED_HOMEDIR}/.tmux"
    chown -R "${DETECTED_PUID}":"${DETECTED_PGID}" "${DETECTED_HOMEDIR}/.tmux.conf"
    chown -R "${DETECTED_PUID}":"${DETECTED_PGID}" "${DETECTED_HOMEDIR}/.tmux.conf.local"
}

# Main Function
main() {
    # Terminal Check
    if [[ -t 1 ]]; then
        check_root
        check_sudo
    fi

    package_management
    kernel_modules
    tmux_config
    tmux_auto
    stricter_defaults
    mergerfs_install
}
main
