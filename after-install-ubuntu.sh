#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# User/Group Information
readonly DETECTED_PUID=${SUDO_UID:-$UID}
readonly DETECTED_UNAME=$(id -un "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_PGID=$(id -g "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_UGROUP=$(id -gn "${DETECTED_PUID}" 2> /dev/null || true)
readonly DETECTED_HOMEDIR=$(eval echo "~${DETECTED_UNAME}" 2> /dev/null || true)

# Root Check Function
root_check() {
    if [[ ${DETECTED_PUID} == "0" ]] || [[ ${DETECTED_HOMEDIR} == "/root" ]]; then
        echo "Running as root is not supported. Please run as a standard user with sudo."
        exit 1
    fi
}

# Cleanup Function
cleanup() {
    local -ri EXIT_CODE=$?

    exit ${EXIT_CODE}
    trap - 0 1 2 3 6 14 15
}
trap 'cleanup' 0 1 2 3 6 14 15

# Main Function
main() {
    # Terminal Check
    if [[ -t 1 ]]; then
        root_check
    fi
    # Sudo Check
    if [[ ${EUID} -ne 0 ]]; then
        echo "Please run with sudo."
        exit 1
    fi

    # System Info
    readonly ARCH=$(uname -m)
    readonly DPKG_ARCH=$(dpkg --print-architecture)
    readonly ID=$(grep --color=never -Po '^ID=\K.*' /etc/os-release)
    readonly VERSION_CODENAME=$(grep --color=never -Po '^VERSION_CODENAME=\K.*' /etc/os-release)

    # apt-get updates, installs, and cleanups
    sudo apt-get -y update
    sudo apt-get -y install \
        apt-transport-https \
        ca-certificates \
        curl \
        fail2ban \
        fonts-powerline \
        fuse \
        git \
        grep \
        htop \
        ncdu \
        python3 \
        python3-pip \
        rsync \
        sed \
        smartmontools \
        tmux
    sudo apt-get -y dist-upgrade
    sudo apt-get -y autoremove
    sudo apt-get -y autoclean

    # kernel modules for vpn
    echo "iptable_mangle" | sudo tee /etc/modules-load.d/iptable_mangle.conf
    echo "tun" | sudo tee /etc/modules-load.d/tun.conf

    # tmux config
    # https://github.com/gpakosz/.tmux
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

    # auto-tmux for SSH logins
    # https://github.com/spencertipping/bashrc-tmux
    if [[ ! -d "${DETECTED_HOMEDIR}/bashrc-tmux" ]]; then
        git clone https://github.com/spencertipping/bashrc-tmux.git "${DETECTED_HOMEDIR}/bashrc-tmux"
    else
        git -C "${DETECTED_HOMEDIR}/.tmux" pull
        git -C "${DETECTED_HOMEDIR}/.tmux" fetch --all --prune
        git -C "${DETECTED_HOMEDIR}/.tmux" reset --hard origin/master
        git -C "${DETECTED_HOMEDIR}/.tmux" pull
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

    # https://help.ubuntu.com/community/StricterDefaults#Shared_Memory
    if ! grep -q '/run/shm' /etc/fstab; then
        echo "none     /run/shm     tmpfs     defaults,ro     0     0" >> /etc/fstab
    fi
    sudo mount -o remount /run/shm || true

    # https://help.ubuntu.com/community/StricterDefaults#SSH_Login_Grace_Time
    sudo sed -i -E 's/^#?LoginGraceTime .*$/LoginGraceTime 20/g' /etc/ssh/sshd_config

    # https://help.ubuntu.com/community/StricterDefaults#Disable_Password_Authentication
    # only disable password authentication if an ssh key with an email address comment at the end is found in the authorized_keys file
    # be sure to setup your ssh key before running this script (and change the user comment at the end to your email address)
    if grep -q -E '^ssh-rsa .* \b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}\b$' "${DETECTED_HOMEDIR}/.ssh/authorized_keys"; then
        sudo sed -i -E 's/^#?PasswordAuthentication .*$/PasswordAuthentication no/g' /etc/ssh/sshd_config
    fi

    # https://help.ubuntu.com/community/StricterDefaults#SSH_Root_Login
    sudo sed -i -E 's/^#?PermitRootLogin .*$/PermitRootLogin no/g' /etc/ssh/sshd_config

    # restart ssh after all the changes above
    sudo systemctl restart ssh

    # https://github.com/rclone/rclone/issues/811#issuecomment-255599253
    sudo sed -i -E 's/^#?user_allow_other$/user_allow_other/g' /etc/fuse.conf

    # https://rclone.org/install/#script-installation
    local GET_RCLONE
    GET_RCLONE=$(mktemp)
    curl -fsSL rclone.org/install.sh -o "${GET_RCLONE}"
    sudo bash "${GET_RCLONE}" || true
    rm -f "${GET_RCLONE}" || true

    # https://github.com/trapexit/mergerfs/releases
    local AVAILABLE_MERGERFS
    AVAILABLE_MERGERFS=$(curl -fsL "https://api.github.com/repos/trapexit/mergerfs/releases/latest" | grep -Po '"tag_name": "[Vv]?\K.*?(?=")')
    local MERGERFS_FILENAME="mergerfs_${AVAILABLE_MERGERFS}.${ID}-${VERSION_CODENAME}_${DPKG_ARCH}.deb"
    curl -fsL "https://github.com/trapexit/mergerfs/releases/download/${AVAILABLE_MERGERFS}/${MERGERFS_FILENAME}" -o "${MERGERFS_FILENAME}"
    sudo dpkg -i "${MERGERFS_FILENAME}"
    rm -f "${MERGERFS_FILENAME}" || true
}
main
