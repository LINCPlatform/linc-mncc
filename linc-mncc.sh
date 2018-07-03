#!/bin/bash
################################################################################
### LINC MASTERNODE CONTROL CENTER v0.2
################################################################################


declare -r SSH_INBOUND_PORT=22
declare -r AUTODETECTED_EXTERNAL_IP=($(ip addr | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p'))

declare -r MN_SWAPSIZE=2000
declare -r MN_USER="linc"
declare -r MN_DAEMON=/usr/local/bin/lincd
declare -r MN_INBOUND_PORT=17222
declare -r MN_CONF_BASEDIR=/home/${MN_USER}/.linc

declare -r DATE_STAMP="$(date +%y-%m-%d-%s)"
declare -r SCRIPTPATH=$( cd $(dirname ${BASH_SOURCE[0]}) > /dev/null; pwd -P )
declare -r MASTERPATH="$(dirname "${SCRIPTPATH}")"
declare -r SCRIPT_VERSION="0.2"
declare -r SCRIPT_LOGFILE="/tmp/linc_mncc_${DATE_STAMP}.log"

declare -r GIT_URL=https://github.com/LINCPlatform/LINC.git
declare -r RELEASE_VERSION="master"
declare -r CODE_DIR="LINC"
declare -r MAX_SLOTS=255

declare -r BINARIES_ARCHIVE_NAME=LINC-1.0.0-linux64.tar.gz
declare -r BINARIES_ARCHIVE_URL=https://linc.site/releases/${BINARIES_ARCHIVE_NAME}

declare -r SYSTEMD_CONF=/etc/systemd/system
declare -r SERVICE_EXEC=/usr/sbin/service

declare -r CURRENT_SCRIPT="$0"
declare -r BINDIR_SCRIPT=/usr/local/bin/linc-mncc

declare -r SELF_UPDATE_URL="https://linc.site/res/linc-mncc.sh"
declare -r SELF_UPDATED="$1"

INSTALLED_MNS=()
RUNNING_MNS=()

IPS=()
USED_IPS=()
FREE_IPS=()


function rd() {
    FG=`echo -ne "\e[38;5;24m"`
    BG=`echo -ne "\e[48;5;15m"`
    read -r -p "$(tput bold)${BG}${FG}${@} $(tput sgr0)${BG}${FG}"
    echo ${REPLY}
}

function output() {
    FG=`echo -ne "\e[38;5;24m"`
    BG=`echo -ne "\e[48;5;15m"`
    printf "${BG}${FG}"
    # printf "$(tput setab 0)$(tput setaf 7)"
    echo "$@"
    printf "${BG}${FG}"
}

function underlined() {
    printf "$(tput smul)"
    echo -n "$@"
    printf "$(tput rmul)"
}

function bold() {
    printf "$(tput bold)"
    echo -n "$@"
    printf "$(tput sgr0)"
}

function error() {
    printf "$(tput setaf 1)"
    echo -n "$@"
    printf "$(tput sgr0)"
}

function success() {
    printf "$(tput setaf 2)"
    echo -n "$@"
    printf "$(tput sgr0)"
}

function warning() {
    printf "$(tput setaf 3)"
    echo -n "$@"
    printf "$(tput sgr0)"
}

function info() {
    printf "$(tput setaf 6)"
    echo -n "$@"
    printf "$(tput sgr0)"
}

function header() {

    output ""
    output ""

    output $(bold "[ LINC MASTERNODE CONTROL CENTER v${SCRIPT_VERSION} ]")

    output ""
    output ""
}


function exit_error() {
    output $(bold $(error $@))
    _exit 1;
}

function _exit() {
    printf "$(tput sgr0)$(tput reset)$(tput clear)"
    exit $1
}

function get_confirmation() {
    response=$(rd "${@:-Are you sure? [y/N]} ")
    case "${response}" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            false
            ;;
    esac
}

function exit_confirmation() {
    get_confirmation "Do you want to continue? [y/N]" || _exit 1
    clear
    header
    list_options
    process_options
}



# checking OS
function check_distro() {
    # currently only for Ubuntu 14.04 & 16.04 & 17.10 & 18.04
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${VERSION_ID}" != "14.04" ]] && [[ "${VERSION_ID}" != "16.04" ]] && [[ "${VERSION_ID}" != "17.10" ]] && [[ "${VERSION_ID}" != "18.04" ]] ; then
            exit_error "This script only supports Ubuntu 14.04 & 16.04 & 17.10 & 18.04 LTS, exiting."
        fi
    else
        exit_error "This script only supports Ubuntu 14.04 & 16.04 & 17.10 & 18.04 LTS, exiting."
    fi
}

# update
function update_system() {
    output ""
    output "Updating system..."
    
    sudo apt-get -y update   &>> ${SCRIPT_LOGFILE}
    # sudo apt-get -y upgrade  &>> ${SCRIPT_LOGFILE}
    sudo apt-get -y autoremove  &>> ${SCRIPT_LOGFILE}
}

# install required packages
function install_packages() {
    output ""
    output "Installing required packages..."

    sudo apt-get -y install wget curl &>> ${SCRIPT_LOGFILE}
}

# creates and activates a swapfile since VPS servers often do not have enough RAM for compilation
function swap_hack() {
    output ""
    if [ $(free | awk '/^Swap:/ {exit !$2}') ] || [ ! -f "/var/mn_swap.img" ];then
        output $(warning "No proper swap, creating it")
        sudo rm -f /var/mn_swap.img
        sudo dd if=/dev/zero of=/var/mn_swap.img bs=1024k count=${MN_SWAPSIZE} &>> ${SCRIPT_LOGFILE}
        sudo chmod 0600 /var/mn_swap.img
        sudo mkswap /var/mn_swap.img &>> ${SCRIPT_LOGFILE}
        sudo swapon /var/mn_swap.img &>> ${SCRIPT_LOGFILE}
        sudo echo '/var/mn_swap.img none swap sw 0 0' | tee -a /etc/fstab &>> ${SCRIPT_LOGFILE}
        sudo echo 'vm.swappiness=10' | tee -a /etc/sysctl.conf               &>> ${SCRIPT_LOGFILE}
        sudo echo 'vm.vfs_cache_pressure=50' | tee -a /etc/sysctl.conf       &>> ${SCRIPT_LOGFILE}
    else
        output "All good, we have a swap"
    fi
}

# firewall
function configure_firewall() {
    output ""
    output "Configuring firewall rules..."
    sudo ufw default deny                          &>> ${SCRIPT_LOGFILE}
    sudo ufw logging on                            &>> ${SCRIPT_LOGFILE}
    sudo ufw allow ${SSH_INBOUND_PORT}/tcp         &>> ${SCRIPT_LOGFILE}
    sudo ufw allow ${MN_INBOUND_PORT}/tcp       &>> ${SCRIPT_LOGFILE}
    sudo ufw limit OpenSSH                         &>> ${SCRIPT_LOGFILE}
    sudo ufw --force enable                        &>> ${SCRIPT_LOGFILE}
}

# creates mn user
function create_mn_user() {
    output ""
    if id "${MN_USER}" >/dev/null 2>&1; then
        output $(info "MN user exists already, do nothing")
    else
        output "Adding new MN user ${MN_USER}..."
        sudo adduser --disabled-password --gecos "" ${MN_USER} &>> ${SCRIPT_LOGFILE}
    fi
}


# get all masternodes
function get_mns() {
    INSTALLED_MNS=()

    for filename in ${SYSTEMD_CONF}/linc-mn*.service; do
        if [ -f ${filename} ]; then
            name=${filename##*/}
            base=${name%.service}
            slot=`echo ${base} | sed -e 's/linc-mn//g'`
            INSTALLED_MNS+=( "${slot}" )
            if is_masternode_running ${slot}; then RUNNING_MNS+=( "${slot}" ); fi
        fi
    done
}

# get used ips
function get_ips() {
    IPS=("${AUTODETECTED_EXTERNAL_IP[@]}")

    USED_IPS=()
    FREE_IPS=()

    for SLOT in "${INSTALLED_MNS[@]}"; do
        filename=${MN_CONF_BASEDIR}-mn${SLOT}/linc.conf
        USED_IPS+=($(cat ${filename} | grep 'externalip=' | sed 's/externalip=//g'))
    done

    for ip1 in "${IPS[@]}"; do
        skip=
        for ip2 in "${USED_IPS[@]}"; do
            [[ $ip1 == $ip2 ]] && { skip=1; break; }
        done;
        [[ -n $skip ]] || FREE_IPS+=("${ip1}")
    done
}

# is slot used
function is_slot_used() {
    SLOT=$1
    for _SLOT in "${INSTALLED_MNS[@]}"; do
        if [[ "mn${SLOT}" == "mn${_SLOT}" ]]; then
            return
        fi
    done
    false
}


# list options
function list_options() {

    output "  1. " $(underlined "Install Masternode")
    output "  2. " $(underlined "Start masternode")
    output "  3. " $(underlined "Stop masternode")
    output "  4. " $(underlined "Restart masternode")
    output "  5. " $(underlined "Masternode status")
    output "  6. " $(underlined "Masternode CLI")
    output "  7. " $(underlined "Remove masternode")
    output "  8. " $(underlined "List all masternodes (installed, running)")
    output "  9. " $(underlined "Generate mastenode.conf content")
    output " 10. " $(underlined "Remove all masternodes")
    output " 11. " $(underlined "Update daemon")
    output " 12. " $(underlined "List IP (all, used, free)")
    output " 13. " $(underlined "Wipe all data (including masternodes)")
    output " 14. " $(underlined "Output debug information")
    output " 15. " $(underlined "Self-update")
    output " 16. " $(underlined "Exit")

    output ""
}

function process_options() {
    get_mns
    get_ips

    option=$(rd "Select option (enter number): ")

    if [[ ! $option =~ ^[0-9]+$ || $option -lt 1 || $option -gt 16 ]]; then
        output $(error $(bold "Invalid option!"))
        exit_confirmation
    fi

    if [[ $option -gt 0 && $option -lt 8 ]]; then
        MN_SLOT=0

        if [[ $option == 1 ]]; then
            if ! is_slot_used 1; then
                MN_SLOT=1
            fi
        fi

        if [[ $option -gt 1 && ${#FREE_IPS[@]} == 0 && ${#IPS[@]} == 1 ]]; then
            if is_slot_used 1; then
                MN_SLOT=1
            fi
        fi

        if [[ ${MN_SLOT} == 0 ]]; then
            MN_SLOT=$(rd "Enter slot number: ")
            if [[ ! ${MN_SLOT} =~ ^[0-9]+$ ]]; then
                output $(error $(bold "Invalid slot!"))
                exit_confirmation
            fi
        fi

        if [[ ${MN_SLOT} -gt ${MAX_SLOTS} ]]; then
            output $(error $(bold "Max slot count is 255!"))
            exit_confirmation
        fi

        if [[ $option -gt 1 ]] && ! is_slot_used ${MN_SLOT}; then
            output $(error $(bold "No masternode installed on this slot!"))
            exit_confirmation
        fi
    fi

    output ""

    case "${option}" in
        1)
            # install mn
            if is_slot_used ${MN_SLOT}; then
                # stop masternode on this slot
                if get_confirmation "$(warning "WARNING! BE AWARE THAT THIS SLOT IS ALREADY USED AND FURTHER ACTIONS WILL REINSTALL MASTERNODE ON THIS SLOT! ARE YOU SURE YOU WANT TO CONTINUE? [ y/N ]")"; 
                then 
                    remove_masternode ${MN_SLOT}
                    output ""
                else exit_confirmation; fi
            fi

            CUSTOM_EXTERNAL_IP=

            if [[ ${#FREE_IPS[@]} -lt 1 ]]; then
                output $(error $(bold "No more IPs!"))
                output ""

                if ! get_confirmation "Do you wish to enter custom IP address? [ Y/n ] "; then
                    exit_confirmation
                fi

                output ""
                CUSTOM_EXTERNAL_IP=$(rd "Enter Masternode IP address: ")
                EXTERNAL_IP=${CUSTOM_EXTERNAL_IP}
                output ""
            else
                EXTERNAL_IP=${FREE_IPS[0]}
            fi

            MN_PKEY=$(rd "Enter your Masternode Private key (a string generated by 'masternode genkey' command) : ")

            if [[ ${#FREE_IPS[@]} -gt 1 ]]; then
                output ""
                output "We detected ${count} IPs on your server:"
                for ip in "${FREE_IPS[@]}"; do output "${ip}"; done
            fi

            output ""
            if [ -z ${CUSTOM_EXTERNAL_IP} ] && ! get_confirmation "Auto-selected MN IP address: ${EXTERNAL_IP} . Is it ok? [ Y/n ] "; then
                EXTERNAL_IP=$(rd "Enter correct MN IP address: ")
            fi

            output ""
            output "Masternode Private Key: ${MN_PKEY}"
            output "Masternode IP address: ${EXTERNAL_IP}"
            get_confirmation "Make sure you double check before continue! Is it ok? [ Y/n ] " || _exit 0

            create_config ${MN_SLOT} ${MN_PKEY} ${EXTERNAL_IP}
            unpack_bootstrap ${MN_SLOT}
            create_systemd_config ${MN_SLOT}
            launch_masternode ${MN_SLOT}

            output ""
            output $(success $(bold "Success! Your LINC masternode has started."))
            output "Now update your Masternode.conf in your local wallet:"
            output $(info "MN${MN_SLOT} ${EXTERNAL_IP}:17222 ${MN_PKEY} <TX_ID> <TX_OUTPUT_INDEX>")
            output ""
            ;;
        2)
            # start mn
            launch_masternode ${MN_SLOT}
            ;;
        3)
            # stop mn
            stop_masternode ${MN_SLOT}
            ;;
        4)
            # stop and start mn
            stop_masternode ${MN_SLOT}
            launch_masternode ${MN_SLOT}
            ;;
        5)  
            # status info
            output $(info "Masternode status: ")
            sudo -u linc /usr/local/bin/linc-cli -datadir="${MN_CONF_BASEDIR}-mn${MN_SLOT}" masternode status
            output ""
            output $(info "Blockchain & network info: ")
            sudo -u linc /usr/local/bin/linc-cli -datadir="${MN_CONF_BASEDIR}-mn${MN_SLOT}" getinfo
            output ""
            ;;
        6) 
            # cli masternode
            CLI_COMMAND=$(rd "Enter CLI command: ")
            sudo -u linc /usr/local/bin/linc-cli -datadir="${MN_CONF_BASEDIR}-mn${MN_SLOT}" "${CLI_COMMAND}"
            output ""
            ;;
        7)
            # stop and remove mn
            if get_confirmation "You're going to remove masternode from this slot! Are you sure? [ y/N ] "; then
                remove_masternode ${MN_SLOT}
            fi
            ;;
        8)
            # list masternodes (all, running, installed)
            output "Masternodes:"
            for SLOT in "${INSTALLED_MNS[@]}"; do
                filename=${MN_CONF_BASEDIR}-mn${SLOT}/linc.conf
                ip=$(cat ${filename} | grep 'externalip=' | sed 's/externalip=//g')
                status='stopped'
                if is_masternode_running ${SLOT}; then status='running'; fi
                output "MN${SLOT} (${ip}): ${status}"
            done
            output ""
            ;;
        9)
            # generate masternode.conf
            output "masternode.conf:"
            for SLOT in "${INSTALLED_MNS[@]}"; do
                filename=${MN_CONF_BASEDIR}-mn${SLOT}/linc.conf
                pkey=$(cat ${filename} | grep 'masternodeprivkey=' | sed 's/masternodeprivkey=//g')
                ip=$(cat ${filename} | grep 'externalip=' | sed 's/externalip=//g')
                output "MN${SLOT} ${ip}:17222 ${pkey} <TX_ID> <TX_OUTPUT_INDEX>"
            done
            output ""
            ;;
        10)
            # remove all masternodes
            output ""
            if get_confirmation "You're going to remove all masternodes! Are you sure? [ y/N ]";
            then 
                sudo killall -9 lincd                                 &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /home/linc/.linc-mn*                 &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /etc/systemd/system/linc-mn*         &>> ${SCRIPT_LOGFILE}

                output $(success "All masternodes removed!")
                output ""
            fi
            ;;
        11)
            # stop running masternodes, reinstall daemon, start masternodes again
            _running_mns=("${RUNNING_MNS[@]}")
            for SLOT in "${_running_mns[@]}"; do
                stop_masternode ${SLOT}
            done
            sudo killall -9 lincd                                 &>> ${SCRIPT_LOGFILE}
            install_daemon
            for SLOT in "${_running_mns[@]}"; do
                launch_masternode ${SLOT}
            done
            ;;
        12)
            # list ips
            output "Server IPs:"
            for IP in ${IPS[@]}; do
                output ${IP}
            done
            output ""
            output "Used IPs:"
            for IP in ${USED_IPS[@]}; do
                output ${IP}
            done
            output ""
            output "Free IPs:"
            for IP in ${FREE_IPS[@]}; do
                output ${IP}
            done
            output ""
            ;;
        13)
            # wipe all data
            output ""
            if get_confirmation "You're going to wipe all masternodes and daemon! Are you sure? [ y/N ]"; 
            then
                sudo killall -9 lincd                                 &>> ${SCRIPT_LOGFILE}
                sudo deluser ${MN_USER}                          &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /usr/local/bin/lincd                 &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /usr/local/bin/linc-cli              &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /usr/local/bin/linc-tx               &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /usr/local/bin/linc-qt               &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /usr/local/bin/test_linc             &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /home/linc                           &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /tmp/linc_mn*                        &>> ${SCRIPT_LOGFILE}
                sudo rm -rf /etc/systemd/system/linc*            &>> ${SCRIPT_LOGFILE}
                rm -rf ${SCRIPTPATH}/${CODE_DIR}                 &>> ${SCRIPT_LOGFILE}
                rm -rf ${SCRIPTPATH}/linc-*                      &>> ${SCRIPT_LOGFILE}
                rm -rf ${SCRIPTPATH}/{BINARIES_ARCHIVE_NAME}     &>> ${SCRIPT_LOGFILE}

                output $(success "All data wiped!")
                output ""
            fi
            ;;
        14)
            # debug information
            output "method unavailable"
            ;;
        15)
            # self-update
            cat > /tmp/linc-mncc-update.sh <<-EOF
#!/bin/bash
wget ${SELF_UPDATE_URL} -O /tmp/linc-mncc.sh || rm -f /tmp/linc-mncc.sh
if [ ! -f /tmp/linc-mncc.sh ]; then
    echo "Self-updating failed!"
    exit 1
fi
sudo mv /tmp/linc-mncc.sh ${BINDIR_SCRIPT}
if [ -f /tmp/linc-mncc.sh ]; then
    echo "Self-updating failed!"
    exit 2
fi
sudo chmod +x ${BINDIR_SCRIPT}
exec linc-mncc self-updated
EOF
            chmod +x /tmp/linc-mncc-update.sh
            exec /tmp/linc-mncc-update.sh
            _exit 0;
            ;;  
        16)
            _exit 0;
            ;;
    esac

    exit_confirmation
}


# first time launch
function init() {
    clear 

    header

    if [[ ! -z "${SELF_UPDATED}" && "${SELF_UPDATED}" == "self-updated" ]]; then
        output "Script successfully updated! Current version is: ${SCRIPT_VERSION}"
        output ""
    fi


    if [ ! -f ${BINDIR_SCRIPT} ]; then
        output "Script is not installed on the system. Installing..."
        install_script
    fi

    if ! id linc > /dev/null 2>&1 || [ ! -f ${MN_DAEMON} ]; then
        if [ $1 ]; then
            exit_error "Initialization error! Aborting."
        fi

        output ""
        output "First time launch. Pre-configuration should be done before using script."
        output ""

        get_confirmation "Pre-configure OS? [ Y/n ] " || _exit 0

        output ""
        output "Pre-configuring OS..."

        check_distro
        update_system
        install_packages
        swap_hack
        configure_firewall
        create_mn_user
        if ! is_daemon_installed; then
            install_daemon
        fi

        output ""
        output $(success $(bold "Initialization done!"))

        sleep 2
        init 1
        return
    fi

    list_options
    process_options
}

# install script
function install_script() {
    output "" 

    sudo cp ${CURRENT_SCRIPT} ${BINDIR_SCRIPT}
    sudo chmod +x ${BINDIR_SCRIPT}

    if [ ! -f ${BINDIR_SCRIPT} ]; then
        exit_error "Can't install script!"
    else
        output $(info "Script successfully installed! You can exit now and run 'linc-mncc'.")
    fi
}

# check node
function is_daemon_installed() {
    [ -f ${MN_DAEMON} ] || false
}

# install
function install_daemon() {
    output ""
    output "Trying to install daemon..."

    cd ${SCRIPTPATH} &>> ${SCRIPT_LOGFILE}
    wget ${BINARIES_ARCHIVE_URL} -O ${BINARIES_ARCHIVE_NAME} &>> ${SCRIPT_LOGFILE} || rm -f ${BINARIES_ARCHIVE_NAME} &>> ${SCRIPT_LOGFILE}
    if [ ! -f ${BINARIES_ARCHIVE_NAME} ]; then
        output $(error "Unable to download latest release. Trying to compile from source code...")
        compile
    else
        tar -xvf ${BINARIES_ARCHIVE_NAME} &>> ${SCRIPT_LOGFILE}
        if [ ! -f ${SCRIPTPATH}/linc-1.0.0/bin/lincd ]; then
            output $(error "Corrupted archive. Trying to compile from source code...")
            compile
        else    
            cd linc-1.0.0/bin &>> ${SCRIPT_LOGFILE}
            ./lincd -version &>> ${SCRIPT_LOGFILE}
            if [ $? -ne 0 ]; then
                output $(error "Compiled binaries launch failed. Trying to compile from source code...")
                compile
            else
                sudo cp * /usr/local/bin/ &>> ${SCRIPT_LOGFILE}
                # if it's not available after installation, there's something wrong
                if [ ! -f ${MN_DAEMON} ]; then
                    output $(error "Installation failed! Trying to complile from source code...")
                    compile
                # else
                    # output ""
                    # output $(success "Daemon installed successfully")
                fi
            fi
        fi
    fi
}

# compile
function compile() {
    output ""
    output "Installing required packages..."

    sudo apt-get -y install software-properties-common build-essential protobuf-compiler libprotobuf-dev \
    libtool autotools-dev automake autoconf-archive pkg-config libssl-dev libcurl4-openssl-dev \
    libevent-dev bsdmainutils libboost-all-dev libminiupnpc-dev libzmq3-dev \
    libgmp3-dev git make apt-utils g++ libcurl3-dev libudev-dev &>> ${SCRIPT_LOGFILE}
    sudo add-apt-repository -y ppa:bitcoin/bitcoin  &>> ${SCRIPT_LOGFILE}
    sudo apt-get -y update  &>> ${SCRIPT_LOGFILE}
    sudo apt-get -y install libdb4.8-dev libdb4.8++-dev  &>> ${SCRIPT_LOGFILE}
    
    # only for 18.04 // openssl
    if [[ "${VERSION_ID}" == "18.04" ]] ; then
       sudo apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install libssl1.0-dev &>> ${SCRIPT_LOGFILE}
    fi

    output ""
     # daemon not found compile it
    if [ ! -d ${SCRIPTPATH}/${CODE_DIR} ]; then
        mkdir -p ${SCRIPTPATH}/${CODE_DIR}              &>> ${SCRIPT_LOGFILE}
    fi

    cd ${SCRIPTPATH}/${CODE_DIR}                        &>> ${SCRIPT_LOGFILE}

    if [ -d ${SCRIPTPATH}/${CODE_DIR}/.git ]; then
        git pull                                        &>> ${SCRIPT_LOGFILE}
    else
        git clone ${GIT_URL} .                          &>> ${SCRIPT_LOGFILE}
    fi

    output "Checking out release version: ${RELEASE_VERSION}"
    git checkout ${RELEASE_VERSION}                     &>> ${SCRIPT_LOGFILE}

    chmod u+x share/genbuild.sh &>> ${SCRIPT_LOGFILE}
    chmod u+x src/leveldb/build_detect_platform &>> ${SCRIPT_LOGFILE}
    chmod u+x ./autogen.sh &>> ${SCRIPT_LOGFILE}

    output "Preparing to build..."
    ./autogen.sh &>> ${SCRIPT_LOGFILE}
    if [ $? -ne 0 ]; then 
        output $(error $(bold "Pre-build failed!"))
        exit_confirmation
    fi

    output "Configuring build options..."
    ./configure --disable-dependency-tracking --disable-tests --disable-bench --with-gui=no --disable-gui-tests --with-miniupnpc=no &>> ${SCRIPT_LOGFILE}
    if [ $? -ne 0 ]; then 
        output $(error $(bold "Configuring failed!"))
        exit_confirmation
    fi

    output "Building LINC... this may take a few minutes..."
    make &>> ${SCRIPT_LOGFILE}
    if [ $? -ne 0 ]; then 
        output $(error $(bold "Build failed!"))
        exit_confirmation
    fi

    output "Installing LINC..."
    sudo make install &>> ${SCRIPT_LOGFILE}
    if [ $? -ne 0 ]; then 
        output $(error $(bold "Installation failed!"))
        exit_confirmation
    fi

    # if it's not available after compilation, theres something wrong
    if [ ! -f ${MN_DAEMON} ]; then
        output $(error $(bold "Unknown error, compilation FAILED!"))
        exit_confirmation
    fi

    output $(success "Daemon compiled and installed successfully")
}


# create service
function create_systemd_config() {
    output ""
    output "Creating systemd config files for MN${1}..."

    MN_CONF_DIR="${MN_CONF_BASEDIR}-mn${1}"
    SERVICE_FILE="${SYSTEMD_CONF}/linc-mn${1}.service"

    sudo bash -c "cat > ${SERVICE_FILE} <<-EOF
[Unit]
Description=LINC masternode daemon
After=network.target

[Service]
User=${MN_USER}
Group=${MN_USER}

Type=forking
PIDFile=${MN_CONF_DIR}/lincd.pid
ExecStart=${MN_DAEMON} -datadir=${MN_CONF_DIR}

Restart=always
RestartSec=5
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=5s
StartLimitInterval=120s
StartLimitBurst=15

[Install]
WantedBy=multi-user.target
EOF"
    if [ -f /bin/systemctl ]; then sudo /bin/systemctl daemon-reload; fi
}


function create_config() {
    output ""
    output "Creating masternode config for MN${1}..."

    MN_CONF_DIR="${MN_CONF_BASEDIR}-mn${1}"
    MN_PKEY=$2
    EXTERNAL_IP=$3

    if [ ! -d "${MN_CONF_DIR}" ]; then sudo mkdir ${MN_CONF_DIR}; fi
    if [ $? -ne 0 ]; then 
        output $(error "Unable to create config directory!")
        exit_confirmation
    fi

    
    NODES_LIST=`wget "https://explorer.linc.site/nodes/?format=conf" -q -O -`
    if [[ ! "${NODES_LIST}" =~ ^addnode=[\d\.]+* ]]; then NODES_LIST=''; fi

    MN_RPCUSER=$(date +%s | sha256sum | base64 | head -c 10 ; echo)
    MN_RPCPASS=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`

    sudo bash -c "cat > ${MN_CONF_DIR}/linc.conf <<-EOF
listen=1
server=1
daemon=1
masternode=1
masternodeprivkey=${MN_PKEY}
bind=${EXTERNAL_IP}
externalip=${EXTERNAL_IP}
rpcbind=127.0.0.${1}
rpcconnect=127.0.0.${1}
rpcallowip=127.0.0.1
rpcuser=${MN_RPCUSER}
rpcpassword=${MN_RPCPASS}
maxconnections=256
addnode=45.77.182.60
addnode=45.76.223.149
addnode=45.77.132.180
addnode=173.199.118.148
addnode=8.9.4.195
addnode=104.156.225.78
${NODES_LIST}
EOF"
    sudo chown -R ${MN_USER}:${MN_USER} ${MN_CONF_DIR} &>> ${SCRIPT_LOGFILE}
}

function unpack_bootstrap() {
    output ""
    output "Unpacking bootstrap for MN${1}..."

    MN_CONF_DIR="${MN_CONF_BASEDIR}-mn${1}"

    sudo -s -- <<EOF
cd ${MN_CONF_DIR} &>> ${SCRIPT_LOGFILE}
wget https://linc.site/res/blockchain.tar.gz &>> ${SCRIPT_LOGFILE}
tar -xvf blockchain.tar.gz &>> ${SCRIPT_LOGFILE}
chown -R ${MN_USER}:${MN_USER} ${MN_CONF_DIR} &>> ${SCRIPT_LOGFILE}
rm -rf blockchain.tar.gz &>> ${SCRIPT_LOGFILE}
EOF
}


function launch_masternode() {
    output ""
    output "Launching masternode MN${1}..."

    sudo ${SERVICE_EXEC} "linc-mn${1}" start  &>> ${SCRIPT_LOGFILE}

    output $(success "Masternode MN${1} has started.")

    get_mns
}

function stop_masternode() {
    output ""
    output "Stopping masternode MN${1}..."

    MN_CONF_DIR="${MN_CONF_BASEDIR}-mn${1}"
    PID=`sudo cat "${MN_CONF_DIR}/lincd.pid" 2>/dev/null` 

    sudo ${SERVICE_EXEC} "linc-mn${1}" stop  &>> ${SCRIPT_LOGFILE}
    if [ ! -z "${PID}" ] && sudo ps -p $PID > /dev/null; then sudo kill -9 $PID; fi

    output $(success "Masternode MN${1} has stopped.")

    get_mns
}

function remove_masternode() {
    stop_masternode ${1}

    output ""
    output "Removing masternode MN${1}..."

    sudo rm -rf /home/linc/.linc-mn${1}                   &>> ${SCRIPT_LOGFILE}
    sudo rm -rf /etc/systemd/system/linc-mn${1}.service   &>> ${SCRIPT_LOGFILE}
    
    output $(success "Masternode MN${1} deleted!")

    get_mns
    get_ips
}

function is_masternode_running() {
    MN_CONF_DIR="${MN_CONF_BASEDIR}-mn${1}"
    PID=`sudo cat "${MN_CONF_DIR}/lincd.pid" 2>/dev/null`
    [ ! -z "${PID}" ] && sudo ps -p $PID > /dev/null || false
}

output ""
tput clear
init
