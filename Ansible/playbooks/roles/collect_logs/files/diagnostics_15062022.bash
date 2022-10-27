#!/bin/bash

### Usage Guide ###
# Common run options
# On ONE VM:
# sudo bash diagnostics.bash
#
# For all other VMs:
# sudo HS_APP_INFO=false bash diagnostics.bash
#
# For most customer cases, please use the above two commands.
# We require at *minimum* docker privileges, and it's best if they have sudo privileges.
# For RHEL8 with podman we require sudo to be able to collect container related information.
# If they do not have sudo, they can run these commands instead (Captures less information):
# On ONE VM:
# NO_SUDO=true bash diagnostics.bash
#
# For all other VMs:
# NO_SUDO=true HS_APP_INFO=false bash diagnostics.bash
#
# Each of these will output a line similar to the following:
# Diagnostics bundle files created:
# /opt/hs/diagnostics/dockerdiag-2021-03-09-234047UTC.tar.gzaa  /opt/hs/diagnostics/dockerdiag-2021-03-09-234047UTC.tar.gzab  /opt/hs/diagnostics/dockerdiag-2021-03-09-234047UTC.tar.gzac
#
# Ask the customer to send the dockerdiag-....tar.gz* file to us from all machines
# Note that we split up files to fit under the Zendesk limit.
# They must be combined before they can be extracted. To combine, you can run this (For example):
# cat dockerdiag-2021-02-23-190545UTC.tar.gz* > dockerdiag-2021-02-23-190545UTC.tar.gz
#
# This can be done even in the case where there's only one file present (dockerdiag-2021-02-23-190545UTC.tar.gzaa).

# Less common run options
# Grab only the most recent 1 hour worth of workflows
# sudo WORKFLOW_EXPORT_PERIOD_IN_SECS=3600 bash diagnostics.bash
# Grab one hour of workflows between:
# (WORKFLOW_EXPORT_LATEST_DT - WORKFLOW_EXPORT_PERIOD_IN_SECS, WORKFLOW_EXPORT_LATEST_DT)
# sudo WORKFLOW_EXPORT_LATEST_DT=2022-01-11T18:00:00-00:00 WORKFLOW_EXPORT_PERIOD_IN_SECS=3600 bash diagnostics.bash
# sudo WORKFLOW_EXPORT_LATEST_DT=2022-01-11T20:00:00-08:00 WORKFLOW_EXPORT_PERIOD_IN_SECS=3600 bash diagnostics.bash
# TBD

### Details ###
# script to capture diagnostic output as a tar.gz
# should be run as root to capture the most useful output
# at the very least must be run with a user with docker privilege

####################

# if this is anything other than "true" will try to produce no stdout/stderr
HS_DIAGNOSTICS_VERBOSE="${HS_DIAGNOSTICS_VERBOSE:-true}"

# this will save last ${HS_LOG_LINES_TO_SAVE} docker logs of all containers
# Defaults to "all" for all logs
HS_LOG_LINES_TO_SAVE="${HS_LOG_LINES_TO_SAVE:--1}"

# this truncate a tar.gz of /var/log after this many bytes
HS_SYSLOGS_MAXBYTES="${HS_SYSLOGS_MAXBYTES:-2000000}"

# Force run without sudo
NO_SUDO="${NO_SUDO:-false}"

# set this env var to "true" collect info about the host file system
# this part of the report can be large in size, ~20MB compressed or more
HS_CHECK_HOST_FS="${HS_CHECK_HOST_FS:-false}"

# Gathers app-related information. Only needs to be done once for the whole cluster
HS_APP_INFO="${HS_APP_INFO:-true}"

HS_CONTAINER_INFO="${HS_CONTAINER_INFO:-true}"

# Container name of container used to run one-off docker commands
# Partial match
HS_APP_INFO_CONTAINER="${HS_APP_INFO_CONTAINER:-shell_command_1}"

# If first argument is passed in, only run that function
HS_SINGLE_CAPTURE="${1}"

# Possible capture arguments
HS_CAPTURE_FNS="capture_host_info capture_docker_daemon_info capture_container_info capture_app_info capture_selinux_info capture_package_info"

# For app info, further splittable by type
HS_APP_INFO_SUB="${HS_APP_INFO_SUB:-system_settings_export,layout_release,usage_report,trained_models_metadata,workflows_definitions,threshold_audits,machine_audit_logs,attached_trainers,latest_trainer_runs,latest_jobs,get_connector_logs,get_configs,init_entries,health_records,health_statistics_records,workflow_instances,workflow_dsls,db_info}"

# Interactive shell
HS_INTERACTIVE_MODE="${HS_INTERACTIVE_MODE:-false}"

# SaaS Deployments run this script inside a container.
# This removes the host-level metrics and assumes that python scripts are run in the docker container's environment.
IS_INSIDE_CONTAINER="${IS_INSIDE_CONTAINER:-false}"

# FIFO used to parse docker exec stderr output
FIFO_OUT=docker_out
# Used to signal to script that we're done and it can end
FIFO_IN=docker_in

# Keep in sync with python code
MAGIC_HEADER="STARTappdiag"

IN_DOCKER_CERTS_DIR="/etc/nginx/certs"
IN_DOCKER_MEDIA_DIR="/var/www/forms/forms/media"
IN_DOCKER_INPUT_DIR="/var/www/forms/forms/input"

DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS="${DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS:-45}"
CAPTURE_PII="${CAPTURE_PII:-false}"
DISTINCT_CORRELATION_IDS_LIMIT="${DISTINCT_CORRELATION_IDS_LIMIT:-50000}"
MAX_WORKFLOW_DOWNLOAD_SECONDS="${MAX_WORKFLOW_DOWNLOAD_SECONDS:-900}"

my_timestamp="$(date "+%Y-%m-%d-%H%M%S%Z")"
my_hostname=$(hostname)
my_dir="dockerdiag-${my_hostname}-${my_timestamp}"

# Split into 49MB chunks, ZD file size
SIZE_SPLIT_LIMIT=49M

# Self hash, as a pseudo-versioning mechanism since we don't have a build process
SELF_HASH="$(sha1sum $0)"
SELF_HASH="${SELF_HASH:0:6}"

function runtime_validation() {

    if [[ -f /etc/redhat-release ]] && grep -q -i 'VERSION="8' /etc/os-release; then
      is_rhel_8="true"
    fi

    HS_DOCKER="docker"
    if [[ "$is_rhel_8" == "true" ]] && which podman >/dev/null; then
      HS_DOCKER="podman"
    elif which docker >/dev/null; then
      if [[ "$is_rhel_8" == "true" ]] ; then
        echo_warn "Running Docker on RHEL 8"
      fi
    fi
    export HS_DOCKER

    ${HS_DOCKER} ps > /dev/null 2>&1
    has_docker_access=$?

    if [[ "${has_docker_access}" == "0" ]]; then
        if [[ $(id -u) -ne 0 ]]; then
            # Docker, no sudo force
            if [[ "${NO_SUDO}" == "true" ]]; then
                myecho "[WARNING] Has ${HS_DOCKER} access but not run with sudo. Please re-run with sudo for best results."
            else
                # Docker, no sudo
                # bypass myecho and force stdout
                echo "[WARNING] Has ${HS_DOCKER} access but not run with sudo. Please re-run with sudo for best results or with NO_SUDO=true."
                exit 1
            fi
        # Docker, sudo
        else
            myecho "Running with full permissions"
        fi
    else
        # No docker
        echo "[ERROR] No ${HS_DOCKER} access. Please re-run with sudo."
        exit 1
    fi
}

function param_validation() {
    # We don't allow interactive shell when running this script inside a container
    if [ "$HS_INTERACTIVE_MODE" == "true" ] && [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
        echo "[ERROR] Interactive Mode is not allowed when running inside a containers: HS_INTERACTIVE_MODE and IS_INSIDE_CONTAINER are both set to 'true'"
        exit 1
    fi

    if [[ -n "${HS_SINGLE_CAPTURE}" ]]; then
        for capture_fn in $HS_CAPTURE_FNS; do
            if [[ "${HS_SINGLE_CAPTURE}" == "${capture_fn}" ]]; then
                return 0
            fi
        done
    else
        return
    fi
    myecho "[WARNING] Extra parameter ${HS_SINGLE_CAPTURE} found. Ignoring..."
    HS_SINGLE_CAPTURE=""

}

function clean_up_previous_runs() {
    container=$(${HS_DOCKER} ps --format '{{.Names}}' | grep "${HS_APP_INFO_CONTAINER}")
    # Clean up code.py files generated prior to RER-340.
    # Otherwise, even though we no longer generate this, diag can still hang indefinitely
    # Can be removed some time sufficiently far in the future, like 2023
    ${HS_DOCKER} exec -it ${container} rm -f /tmp/code.py

    # Clear out old, stale diagnostics
    if [[ ! -z "${HS_DIAGNOSTICS_BASE_DIR}" ]]; then
        find "${HS_DIAGNOSTICS_BASE_DIR}" -maxdepth 1 -mindepth 1 -mtime +7 -exec rm -rf {} \;
    fi

    # Kills stale python processes from previous runs
    kill -9 $(ps ax | grep 'python /tmp/code.py' | grep -v grep | cut -d ' ' -f 1) > /dev/null 2>&1
    kill -9 $(ps ax | grep 'python /tmp/hs_diag.py' | grep -v grep | cut -d ' ' -f 1) > /dev/null 2>&1
}

function main() {

    runtime_validation

    # output directory in which files are collected and resulting tarball created
    # Default to ${HS_PATH}/diagnostics
    eval $(get_hs_var "HS_PATH") > /dev/null 2>&1
    HS_PATH="${HS_PATH:-/opt/hs}"
    HS_DIAGNOSTICS_BASE_DIR="${HS_DIAGNOSTICS_BASE_DIR:-${HS_PATH}/diagnostics}"

    clean_up_previous_runs

    param_validation

    if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
        capture_app_info
        exit 0
    fi

    mkdir -p "${HS_DIAGNOSTICS_BASE_DIR}/${my_dir}"

    create_base_dir_rc="$?"

    if [[ "$create_base_dir_rc" -ne 0 ]]; then

        echo "creating base dir failed with return code $create_base_dir_rc"
        exit "$create_base_dir_rc"
    fi

    cd "${HS_DIAGNOSTICS_BASE_DIR}/${my_dir}"

    myecho "whoami '$(whoami)'"

    myecho "hostname -f '$(hostname -f)'"

    capture_docker_daemon_info

    capture_host_info

    capture_selinux_info

    capture_package_info

    if [[ "${HS_CONTAINER_INFO}" == "true" ]]; then
        containers=$(${HS_DOCKER} ps -a | awk '{if(NR>1) print $NF}')
        for container in $containers; do
            capture_container_info "$container"
        done
    fi

    capture_current_env_hash

    if [[ "${HS_APP_INFO}" == "true" ]]; then
        capture_app_info
    fi

    cd "${HS_DIAGNOSTICS_BASE_DIR}"
    tar czf "${HS_DIAGNOSTICS_BASE_DIR}/${my_dir}.tar.gz" "${my_dir}"
    split -b${SIZE_SPLIT_LIMIT} "${my_dir}.tar.gz" "${my_dir}.tar.gz"
    rm "${my_dir}.tar.gz"
    rm -rf "${HS_DIAGNOSTICS_BASE_DIR}/${my_dir}"

    # not using myecho, we want this message to be echoed always
    echo "Diagnostics bundle files created:"
    ls ${HS_DIAGNOSTICS_BASE_DIR}/${my_dir}.tar.gz*
    echo "Send these file(s) to app."
}

function myecho() {
    if [[ "${HS_DIAGNOSTICS_VERBOSE}" == "true" ]]; then
        echo "$(date "+%Y-%m-%d-%H%M%S%Z") $SELF_HASH $1" |
            tee -a ./hs-diagnostics.log
    else
        echo "$(date "+%Y-%m-%d-%H%M%S%Z") $SELF_HASH $1" \
            >>./hs-diagnostics.log
    fi
}

# Can be eval'd directly
function get_hs_var() {
    container=$(${HS_DOCKER} ps --format '{{.Names}}' | grep "${HS_APP_INFO_CONTAINER}")
    ${HS_DOCKER} inspect -f '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' "${container}" 2>&1 | grep "${1}"
}

function capture_host_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    mkdir -p host

    if [[ "${HS_CHECK_HOST_FS}" == "true" ]]; then
        myecho "checking host file system usage"
        du -ac / \
            2>&1 |
            gzip \
                >./host/du.txt.gz
    else
        myecho "skipping host file system check"
    fi

    myecho "capture hostname"
    hostname -f > ./host/hostname.txt

    myecho "capture os-release"
    cat /etc/os-release &> ./host/os-release

    myecho "copying /etc/mtab"
    cp /etc/mtab ./host/mtab

    myecho "copying /etc/fstab"
    cp /etc/fstab ./host/fstab

    myecho "capturing dmesg -T"
    dmesg -T >./host/dmesg.txt

    myecho "listing files in var/log"
    find /var/log -type f >./host/log_files.txt

    myecho "capturing all host logs"
    tar czf - --newer-mtime '8 days ago' -C / var/log \
        2>>./hs-diagnostics.log |
        head -c "${HS_SYSLOGS_MAXBYTES}" \
            >./host/logs.tar.gz

    myecho "capturing host processes"
    ps -ef >./host/ps_ef.txt

    myecho "capturing top output"
    top -n 1 >./host/top.txt

    myecho "capturing df output"
    df >./host/df.txt

    myecho "capturing df inodes output"
    df -i >./host/df_inodes.txt

    myecho "copying cron jobs defined as files"
    find /etc/cron.* -type f -exec \
        bash -c 'echo "cronfile {}" >> ./host/cronfiles.txt ; cat {} >> ./host/cronfiles.txt' \;

    mkdir -p host/crontab
    myecho "copying user crontabs"
    for user in $(getent passwd | cut -f1 -d:); do
        crontab -u $user -l >./host/crontab/$user.txt 2>&1
    done

    myecho "checking sestatus -v"
    sestatus -v >./host/sestatus.txt 2>&1

    myecho "checking apparmost_status -v"
    apparmor_status --verbose >./host/apparmor_status.txt 2>&1

    myecho "lsmem"
    lsmem >./host/lsmem.txt 2>&1

    myecho "lscpu"
    lscpu >./host/lscpu.txt 2>&1

    myecho "copying /proc/cpuinfo"
    cp /proc/cpuinfo ./host/cpuinfo

    myecho "copying /proc/meminfo"
    cp /proc/meminfo ./host/meminfo

    myecho "checking loadavg"
    cat /proc/loadavg > ./host/loadavg

    myecho "free -m"
    free -m > ./host/free-m.txt

    myecho "cat /etc/*release*"
    cat /etc/*release* > releaseinfo.txt 2>&1

    myecho "cat /etc/resolv.conf"
    cat /etc/resolv.conf > resolvconf.txt

    myecho "cat /etc/nsswitch.conf"
    cat /etc/nsswitch.conf > nsswitchconf.txt

    myecho "netstat -aptn"
    netstat -aptn > ./host/netstat.txt

    myecho "ss -aptn"
    ss -aptn > ./host/ss.txt

    myecho "lsof -a -i4 -itcp"
    lsof -a -i4 -itcp > ./host/lsof.txt

    # systemd DNS resolver, may not exist on all OSes
    systemd-resolve --status > systemdresolve.txt 2>&1

    myecho "systemctl list-units"
    systemctl list-units > host/systemd_units.txt 2>&1
}

function capture_selinux_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    local target_dir="./host/selinux"
    mkdir -p "$target_dir"

    myecho "checking sestatus -v"
    sestatus -v &>$target_dir/sestatus.txt

    myecho "exporting semanage custom customizations"
    semanage export -f $target_dir/semanage_export.txt &>$target_dir/semanage_export.log

    local semanage_items=(port interface module node fcontext boolean permissive)
    for item in ${semanage_items[@]}; do
        myecho "collecting semanage $item"
        semanage $item --list &> $target_dir/$item.txt
    done
}

function capture_package_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    local target_dir="./host/packageinfo"
    mkdir -p "$target_dir"

    myecho "collecting rpm -qa"
    rpm -qa &>$target_dir/rpm-qa.txt

    myecho "collecting yum list installed"
    yum list installed &>$target_dir/yum.txt

    myecho "collecting snap list --all"
    snap list --all &>$target_dir/snap.txt

    myecho "collecting apt list --installed"
    apt list --installed &>$target_dir/apt.txt

    myecho "collecting dpkg-query -l"
    dpkg-query -l &>$target_dir/dpkg-query.txt
}

function capture_docker_daemon_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    mkdir -p docker

    myecho "checking ${HS_DOCKER} system df -v"
    ${HS_DOCKER} system df -v >./docker/docker_system_df.txt 2>&1

    myecho "checking ${HS_DOCKER} ps -a -s"
    ${HS_DOCKER} ps -a -s >./docker/docker_ps.txt 2>&1

    myecho "checking ${HS_DOCKER} system events"
    ${HS_DOCKER} system events --since 300h --until 0m >./docker/docker_system_events.txt 2>&1

    myecho "checking ${HS_DOCKER} info"
    ${HS_DOCKER} info >./docker/docker_info.txt 2>&1

    # TODO: Verify if this varies depending on docker installation
    myecho "get docker daemon.json"
    cat /etc/docker/daemon.json > ./docker/docker_daemon.json 2>&1

    # the calls below are RHEL specific
    myecho "get docker seccomp.json"
    cat /etc/docker/seccomp.json &> ./docker/docker_seccomp.json

    myecho "get sysconfig docker files"
    cat /etc/sysconfig/docker &> ./docker/sysconfig_docker
    cat /etc/sysconfig/docker-storage &> ./docker/sysconfig_docker_storage
    cat /etc/sysconfig/docker-network &> ./docker/sysconfig_docker_network

    myecho "get podman config"
    cp -r /etc/containers ./docker

    myecho "get podman systemd status"
    systemctl status podman.socket &> ./docker/systemd_podman_socket_status
    systemctl status podman.service &> ./docker/systemd_podman_service_status
    systemctl status podman-restart.service &> ./docker/systemd_podman_restart_service_status

    myecho "get podman systemd config"
    systemctl cat podman.socket &> ./docker/systemd_podman_socket
    systemctl cat podman.service &> ./docker/systemd_podman_service
    systemctl cat podman-restart.service &> ./docker/systemd_podman_restart_service

}

function capture_container_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    local container="$1"
    local forms_image_version
    local forms_image=forms
    forms_image_version=$(${HS_DOCKER} images | grep forms | awk '{print $2}')

    mkdir -p "containers/${container}"

    myecho "capturing logs for container $container"

    ${HS_DOCKER} logs --tail ${HS_LOG_LINES_TO_SAVE} $container 2>&1 |
        gzip \
            >./containers/${container}/log.gz

    myecho "capturing container file system usage for container $container"
    # should be true if the container is running
    if ${HS_DOCKER} ps | grep -q -w $container; then
        ${HS_DOCKER} exec -u=0 $container \
            /var/www/venv/bin/pip freeze \
            >./containers/${container}/pip-freeze.txt

        ${HS_DOCKER} exec -u=0 $container \
            apt list --installed \
            >./containers/${container}/apt-list-installed.txt
    fi

    myecho "capturing container internal logs for container $container"
    ${HS_DOCKER} cp $container:/var/log ./containers/${container}/var_log

    myecho "compressing container internal logs"
    tar czf ./containers/${container}/var_log.tar.gz -C ./containers/${container}/ var_log
    rm -rf ./containers/${container}/var_log

    myecho "${HS_DOCKER} inspect $container"

    local now
    now=$(date +"%s")
    ${HS_DOCKER} inspect  "${container}" |
        docker run --name "hs_docker_inspect_$now" --rm -i \
        "$forms_image:$forms_image_version" /var/www/venv/bin/python -c 'import json; import sys; d = json.load(sys.stdin); d[0]["Config"].pop("Env", None); print(json.dumps(d, indent=4))' \
        > "./containers/${container}/inspect.json"

    container_image=$("${HS_DOCKER}" inspect -f '{{ .Config.Image }}' "${container}")
    is_container_running=$("${HS_DOCKER}" inspect -f '{{ .State.Running }}' "${container}")

    if [[ "$is_container_running" == "true" ]]; then
        if [[ "$container_image" =~ "forms".* || "$container_image" =~ "trainer".* ]]; then
          ${HS_DOCKER} exec -i "${container}" bash -c "cd /var/www/forms/forms; /var/www/venv/bin/python -c 'import json; from common.system_variable import SystemVariable; print(json.dumps(SystemVariable.redacted_app_variables(), indent=4))'" \
            > "./containers/${container}/app_variables.json"

          ${HS_DOCKER} exec -i "${container}" bash -c "cd /var/www/forms/forms; /var/www/venv/bin/python -c 'import json; from common.system_variable import SystemVariable; print(json.dumps(SystemVariable.redacted_env_variables(), indent=4))'" \
            > "./containers/${container}/env_variables.json"

          myecho "certs directory within $container"
          ${HS_DOCKER} exec -it "${container}" ls -R "${IN_DOCKER_CERTS_DIR}"

          eval $(${HS_DOCKER} inspect -f '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' "${container}" | grep FORMS_STORAGE_MODE)
          if [[ "${FORMS_STORAGE_MODE}" == "FILE" ]]; then
              myecho "checking access to media dir within $container"
              {
                  test_file_name="${container}_$(date "+%Y-%m-%d-%H%M%S%Z")_access"
                  host_media=$(${HS_DOCKER} inspect -f '{{range .Mounts}}{{printf "%s\n%s\n" .Source .Destination}}{{end}}' "${container}" | grep -v "${IN_DOCKER_MEDIA_DIR}" | grep "/media$")
                  if [[ ! -z "$host_media" ]]; then
                      ${HS_DOCKER} exec -it "${container}" touch "${IN_DOCKER_MEDIA_DIR}/${test_file_name}"
                      test -f "${host_media}/${test_file_name}" || myecho "Media directory out of sync between ${container} and host"
                      ${HS_DOCKER} exec -it "${container}" rm "${IN_DOCKER_MEDIA_DIR}/${test_file_name}"
                  else
                      myecho "Not checking media dir access because media dir is not set"
                  fi
              } >./containers/${container}/media_test.txt 2>&1
          else
              myecho "Not checking media dir access because storage mode is ${FORMS_STORAGE_MODE}"
          fi

          myecho "checking access to input dir within $container"
          {
              test_file_name="${container}_$(date "+%Y-%m-%d-%H%M%S%Z")_access"
              host_input=$(${HS_DOCKER} inspect -f '{{range .Mounts}}{{printf "%s\n%s\n" .Source .Destination}}{{end}}' "${container}" | grep -v "${IN_DOCKER_INPUT_DIR}" | grep "/input$")
              if [[ ! -z "$host_input" ]]; then
                  ${HS_DOCKER} exec -it "${container}" touch "${IN_DOCKER_INPUT_DIR}/${test_file_name}"
                  test -f "${host_input}/${test_file_name}" || myecho "Input directory out of sync between ${container} and host"
                  ${HS_DOCKER} exec -it "${container}" rm "${IN_DOCKER_INPUT_DIR}/${test_file_name}"
              else
                  myecho "Not checking input dir access because input dir is not set"
              fi
          } >./containers/${container}/input_test.txt 2>&1
        fi

        ${HS_DOCKER} exec -i "${container}" cat /etc/resolv.conf > "./containers/${container}/resolvconf.txt"

        ${HS_DOCKER} exec -i "${container}" cat /etc/nsswitch.conf > "./containers/${container}/nsswitchconf.txt"
    else
      myecho "container is not running $container"
    fi
}

function capture_system_settings_export() {
    run_embedded_python "capture_system_settings_export"
}

function capture_layout_release() {
    run_embedded_python "capture_layout_release"

}

function capture_usage_report() {
    run_embedded_python "capture_usage_report"
}

function capture_trained_models_metadata() {
    run_embedded_python "capture_trained_models_metadata"
}

function capture_threshold_audits() {
    run_embedded_python "capture_threshold_audits"
}

function capture_machine_audit_logs() {
    run_embedded_python "capture_machine_audit_logs"
}

function capture_attached_trainers() {
    run_embedded_python "capture_attached_trainers"
}

function capture_latest_trainer_runs() {
    run_embedded_python "capture_latest_trainer_runs"
}

function capture_latest_jobs() {
    run_embedded_python "capture_latest_jobs"
}

function capture_connector_logs() {
    run_embedded_python "capture_connector_logs"
}

function capture_configs() {
    run_embedded_python "capture_configs"
}

function capture_init_entries() {
    run_embedded_python "capture_init_entries"
}

function capture_health_records() {
    run_embedded_python "capture_health_records"
}

function capture_health_statistics_records() {
  run_embedded_python "capture_health_statistics_records"
}

function capture_workflow_instances() {
  run_embedded_python "capture_workflow_instances"
}

function capture_workflows_definitions() {
  run_embedded_python "capture_workflows_definitions"
}

function capture_workflow_dsls() {
  run_embedded_python "capture_workflow_dsls"
}

function capture_db_info() {
  run_embedded_python "capture_db_info"
}

function noop() {
    return 0
}

function run_embedded_python() {
    # Write to shell_plus script
    code="${code}
${1}()"
}

# Helper to parse docker stderr
# Primarily to stream files through stderr
function slurp_stderr_fifo() {
    while read -r line; do
        if [[ "${line}" =~ ${MAGIC_HEADER}(.*) ]]; then
            file_name=${BASH_REMATCH[1]}
            myecho "Writing ${file_name}"
            # Has a file, outsource processing to python because bash is hard
            # and read will drop NUL bytes
            ${HS_DOCKER} exec -i "${container}" bash -c "echo \"${CODE}\" > /tmp/run.py; echo \"write_file()\" >> /tmp/run.py; /var/www/venv/bin/python /tmp/run.py; rm /tmp/run.py" >"${file_name}" <"${FIFO_OUT}"
            # Continue signal
            echo > "${FIFO_IN}"
        else
            myecho "${line}" >&2
        fi
    done <"${FIFO_OUT}"
}

# TODO: App change to improve this heuristic
# Best guess right now based on common customer configurations
function capture_current_env_hash() {
    eval $(get_hs_var "HS_SDM_BLOCKS_PATH")
    # This var doesn't exist before R30
    # Even if it exists, it is overridable and does NOT need to be
    # in the same path as the bundle, although that is the default configuration.
    if [[ ! -z ${HS_SDM_BLOCKS_PATH} ]]; then
        possible_bundle_dir=${HS_SDM_BLOCKS_PATH}/..
    fi

    find ${HS_PATH} ${possible_bundle_dir} "/opt/hs" "/mnt/hs" -mount -not -path "*media*" -name ".env" -exec sha1sum {} \; | sort | uniq > ./hash.txt 2>&1
}

function capture_app_info() {
    if [[ -n "${HS_SINGLE_CAPTURE}" && "${HS_SINGLE_CAPTURE}" != "${FUNCNAME[0]}" ]]; then
        return 0
    fi

    capture_system_settings_export="capture_system_settings_export"
    capture_layout_release="capture_layout_release"
    capture_usage_report="capture_usage_report"
    capture_trained_models_metadata="capture_trained_models_metadata"
    capture_threshold_audits="capture_threshold_audits"
    capture_machine_audit_logs="capture_machine_audit_logs"
    capture_attached_trainers="capture_attached_trainers"
    capture_latest_trainer_runs="capture_latest_trainer_runs"
    capture_latest_jobs="capture_latest_jobs"
    capture_connector_logs="capture_connector_logs"
    capture_configs="capture_configs"
    capture_init_entries="capture_init_entries"
    capture_health_records="capture_health_records"
    capture_workflow_instances="capture_workflow_instances"
    capture_workflows_definitions="capture_workflows_definitions"
    capture_workflow_dsls="capture_workflow_dsls"
    capture_health_statistics_records="capture_health_statistics_records"
    capture_db_info="capture_db_info"

    if [[ "$IS_INSIDE_CONTAINER" == "false" ]]; then
        container=$(${HS_DOCKER} ps --format '{{.Names}}' | grep "${HS_APP_INFO_CONTAINER}")
        application_version=$(${HS_DOCKER} exec -it "${container}" bash -c $'cat forms/forms/FORMS_VERSION  | /var/www/venv/bin/python -c "import sys, json; print(json.load(sys.stdin)[\'version\'], end=\'\')"')
    else
        application_version=$(cat /var/www/forms/forms/FORMS_VERSION | /var/www/venv/bin/python -c "import sys, json; print(json.load(sys.stdin)['version'], end='')")
    fi

    major_version=${application_version%%.*}
    minor_version=${application_version#*.}
    minor_version=${minor_version%%.*}
    # Unused, for future reference
    patch_version=${application_version##*.}

    # Useful for overriding built-in functions with improved implementations, etc.
    # Or behavioral differences between versions
    # TODO: More flexible version parsing (range, gte/lte, etc.)
    case "${major_version}" in
    "27"|"28")
        capture_health_statistics_records="noop"
        capture_workflow_instances="noop"
        capture_workflows_definitions="noop"
        capture_workflow_dsls="noop"
        ;;
    *)
        myecho "Using defaults"
        ;;
    esac

    # Load function definitions

    code="${CODE}"

    {
        if [[ "${HS_INTERACTIVE_MODE}" != "true" ]]; then
            IFS=","
            for subtype in ${HS_APP_INFO_SUB}; do
                fn_name="capture_${subtype}"
                eval "${!fn_name}"
            done
            code="
${code}
"
        else
            # Load Django in interactive mode
            code="
${CODE}
django_ctx()()
"
        fi
    }

    # Note from Steve: Not sure if this does anything?
    echo "${code}" >> "capture_app_info.py"

    docker_env_vars=(
        "-e" "DJANGO_LOG_LEVEL=DEBUG"
        "-e" "PYTHONUNBUFFERED=true"
        "-e" "DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS=${DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS}"
        "-e" "WORKFLOW_EXPORT_LATEST_DT=${WORKFLOW_EXPORT_LATEST_DT}"
        "-e" "WORKFLOW_EXPORT_PERIOD_IN_SECS=${WORKFLOW_EXPORT_PERIOD_IN_SECS}"
        "-e" "CAPTURE_PII=${CAPTURE_PII}"
        "-e" "DISTINCT_CORRELATION_IDS_LIMIT=${DISTINCT_CORRELATION_IDS_LIMIT}"
        "-e" "MAX_WORKFLOW_DOWNLOAD_SECONDS=${MAX_WORKFLOW_DOWNLOAD_SECONDS}"
    )

    if [[ "${IS_INSIDE_CONTAINER}" == "true" ]]; then
        export DJANGO_LOG_LEVEL=DEBUG
        export PYTHONUNBUFFERED=true
        export DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS="${DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS}"
        export WORKFLOW_EXPORT_DEFAULT_PERIOD_IN_DAYS="${WORKFLOW_EXPORT_DEFAULT_PERIOD_IN_DAYS}"

        # Skipping CAPTURE_PII since we never want to send PII to stdout

        source /var/www/venv/bin/activate && cd /var/www/forms/forms/ || exit 1
        echo "${code}" > /tmp/hs_diag.py
        python /tmp/hs_diag.py 2| cat

    elif [[ "${HS_INTERACTIVE_MODE}" != "true" ]]; then
        mkfifo "${FIFO_OUT}"
        mkfifo "${FIFO_IN}"
        # Keep FIFO_IN open until we're done with it
        sleep infinity >> "${FIFO_IN}" &
        pid=$!
        disown
        ${HS_DOCKER} exec -i "${container}" bash -c "unset SENTRY_DSN; echo \"${code}\" > /tmp/hs_diag.py" >> docker_exec.log
        ${HS_DOCKER} exec ${docker_env_vars[@]} -i "${container}" bash -c "unset SENTRY_DSN; source /var/www/venv/bin/activate; cd /var/www/forms/forms/; python /tmp/hs_diag.py" < ${FIFO_IN} 2>${FIFO_OUT} >> docker_exec.log &
        slurp_stderr_fifo 2>&1 | tee -a docker_exec.log
        # Close FIFO_IN pipe to end docker exec
        kill $pid
    else
        ${HS_DOCKER} exec -it "${container}" bash -c "unset SENTRY_DSN; echo \"${code}\" > /tmp/hs_diag.py" 2>/dev/null
        ${HS_DOCKER} exec ${docker_env_vars[@]} -it "${container}" bash -c "unset SENTRY_DSN; source /var/www/venv/bin/activate; cd /var/www/forms/forms/; python -i /tmp/hs_diag.py" 2>/dev/null
    fi
}

####################################################################################
#              Python code goes here
# TODO: Do we want to split this up by file and introduce a build process?
# TODO: Embedding means no linter checks
####################################################################################
read -r -d '' CODE <<EOM
import copy
import csv
import io
import itertools
import json
import logging
import os
import sys
import threading
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta
from distutils.util import strtobool
from functools import wraps
from typing import Any, Dict

from django.db.models import Max
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from requests import HTTPError

logger = logging.getLogger(__name__)

# Standardize import path to be what we normally expect
sys.path.append('/var/www/forms/forms')


DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS = int(os.environ.get('DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS', 45))

# Example format: 2022-01-11T03:28:38-05:00
# Defaults to now
try:
    _start_dt = os.environ.get('WORKFLOW_EXPORT_LATEST_DT')
    if _start_dt:
        WORKFLOW_EXPORT_LATEST_DT = parse_datetime(_start_dt)
    else:
        WORKFLOW_EXPORT_LATEST_DT = datetime.now(timezone.utc)
except:
    logger.exception('Failed to parse WORKFLOW_EXPORT_LATEST_DT: %s', _start_dt)

# Default to 3 days
WORKFLOW_EXPORT_PERIOD_IN_SECS = int(
    os.environ.get('WORKFLOW_EXPORT_PERIOD_IN_SECS') or 3 * 24 * 60 * 60
)
# Number of distinct correlation ids to get
# Note that each correlation id may be associated with multiple workflows
# So there's a multiplier effect on the total number of workflows
DISTINCT_CORRELATION_IDS_LIMIT = int(os.environ.get('DISTINCT_CORRELATION_IDS_LIMIT', 50000))
MAX_WORKFLOW_DOWNLOAD_SECONDS = int(os.environ.get('MAX_WORKFLOW_DOWNLOAD_SECONDS', 900))
CAPTURE_PII = strtobool(os.environ.get('CAPTURE_PII', 'false'))

IS_INSIDE_CONTAINER = strtobool(os.environ.get('IS_INSIDE_CONTAINER', 'false'))

def continue_on_exception(f):
    @wraps(f)
    def inner(*args, **kwargs):
        try:
            f(*args, **kwargs)
        except:
            logger.exception('Continuing...')

    return inner


def django_ctx(f=None):
    def preload_django():
        import django

        django.setup()
        if f is not None:
            f()

    return preload_django


# Helper to pass pipe data from docker into a file without using a mount
# Uses stderr, and prone to interleaving issues if non-file data is written to stderr in between
class File:
    # Keep in sync with diagnostics.bash
    # Pseudo-binary because we're limited to stdout/stderr
    # and parts of this flow through bash
    # TODO: Improve this(?)
    MAGIC_HEADER = 'STARTappdiag'
    MAGIC_FOOTER = 'ENDappdiag'

    def __init__(self, file_name):
        self.f = os.fdopen(sys.stderr.fileno(), 'wb', closefd=False)
        self.write('\n')
        self.write(self.MAGIC_HEADER)
        self.write(file_name)
        self.write('\n')
        self.is_open = True

    def __enter__(self):
        return self.f

    def __exit__(self, type, value, traceback):
        self.complete()

    def write(self, b):
        self.f.write(bytes(b, 'utf8'))

    def complete(self):
        if self.is_open:
            self.is_open = False
            self.write('\n')
            self.write(self.MAGIC_FOOTER)
            self.write('\n')
            self.f.flush()

            if not IS_INSIDE_CONTAINER:
                # Wait for signal to continue
                # Without this synchronization the FIFO_OUT pipe gets
                # killed after the first file is read from stderr
                input()


def write_file():
    last_line = None
    magic_footer_string = File.MAGIC_FOOTER + '\n'
    for line in sys.stdin:
        if line == magic_footer_string:
            # newline is a part of the magic footer and should
            # be removed
            print(last_line.rstrip(), end='')
            sys.exit(0)
        if last_line is not None:
            print(last_line, end='')
        last_line = line


def write_csv(file_name, headers, data):
    with File(file_name) as f:
        tf = io.TextIOWrapper(f, encoding='utf8', newline='')
        writer = csv.DictWriter(tf, fieldnames=headers)
        writer.writeheader()
        for row in data:
            writer.writerow(row)
        # To keep f valid
        tf.detach()


def write_json(file_name, data):
    with File(file_name) as f:
        f.write(bytes(json.dumps(data, indent=3), 'utf8'))


@continue_on_exception
@django_ctx
def capture_workflows_definitions():
    from sdm.models import WorkflowVersion

    wf_definitions = WorkflowVersion.objects.all().values_list('dsl', flat=True)
    DEFINITIONS_FILE_NAME = 'wf_defs.json'
    write_json(DEFINITIONS_FILE_NAME, list(wf_definitions))


@continue_on_exception
@django_ctx
def capture_system_settings_export():
    from form_extraction.settings.export_utils import (
        transform_settings_for_export,
        _transfer_template_by_keys,
    )
    from form_extraction.settings.views import _get_current_configs

    class User:
        def has_perm(*args, **kwargs):
            return True

    SETTINGS_NAME = 'settings.json'

    settings = transform_settings_for_export(
        _get_current_configs(), list(_transfer_template_by_keys().keys()), None, User(), ''
    )
    write_json(SETTINGS_NAME, settings)


@continue_on_exception
@django_ctx
def capture_layout_release():
    from common.utils.zip_utils import generate_zipped_stream
    from form_extraction.layouts.impex.library_export import LibraryExporter
    from form_extraction.models import Config

    config = Config.get_config()

    exporter = LibraryExporter()

    generator = getattr(exporter, 'release_generator', None)

    # Backwards compatibility for pre-R30
    if generator is None:
        generator = exporter.generator

    # Backwards compatibility for pre-R32
    try:
        from form_extraction.layouts.services.template_release_service import get_live_release_uuids
        release_uuids = get_live_release_uuids()
    except ImportError:
        release_uuids = [config.active_template_release_id]

    for release_uuid in release_uuids:
        stream = generate_zipped_stream(generator(release_uuids=[release_uuid]))

        with File(f'layout_release_{release_uuid}.zip') as f:
            for chunk in stream:
                f.write(chunk)


@continue_on_exception
@django_ctx
def capture_usage_report():
    from common.utils.zip_utils import generate_zipped_stream
    from form_extraction.models import FeatureConfig
    from reports import application_usage_zip
    from reports.parameters import ApplicationUsageValidator

    REPORT_PERIOD_IN_DAYS = DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS
    CONFIG = FeatureConfig.get_config()
    DATA = {
        'aggregation': 'DAILY',
        'csv': True,
        'start_date': date.today() - timedelta(REPORT_PERIOD_IN_DAYS),
        'product_analytics': False,
    }

    # Backwards compatibility pre R32
    try:
        app_usage_validator = ApplicationUsageValidator(data=DATA)
    except:
        app_usage_validator = ApplicationUsageValidator(feature_config=CONFIG, data=DATA)

    # Backwards compatibility pre R32
    try:
        generator = application_usage_zip.generator(params=DATA)
    except:
        # Backwards compatibility pre R30
        try:
            generator = application_usage_zip.generator(app_usage_validator, params=DATA, feature_config=CONFIG, request=None)
        except:
            generator = application_usage_zip.generator(app_usage_validator, params=DATA, feature_config=CONFIG)

    with File(application_usage_zip.filename(app_usage_validator, DATA)) as f:
        for chunk in generate_zipped_stream(generator, zipfile.ZIP_DEFLATED):
            f.write(chunk)


@continue_on_exception
@django_ctx
def capture_trained_models_metadata():
    from forms_qa.models import FinetuningModelMeta

    FIELDS_TO_EXPORT = ['id', 'dt_started', 'dt_completed', 'train_status']
    # Backwards compatibility, pre-R28 field_type does not exist
    if hasattr(FinetuningModelMeta, 'field_type'):
        FIELDS_TO_EXPORT.append('field_type')
    FIELDS_TO_EXPORT.extend(['base_model_version', 'name', 'info'])
    FT_META_FNAME = 'ft_model_meta.csv'

    metas = (
        FinetuningModelMeta.objects.filter(
            dt_started__gt=timezone.now() - timedelta(days=DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS)
        )
        .order_by('-id')
        .values(*FIELDS_TO_EXPORT)
    )

    write_csv(FT_META_FNAME, FIELDS_TO_EXPORT, metas)


@continue_on_exception
@django_ctx
def capture_threshold_audits():
    from django.utils import timezone
    from forms_qa.models import ThresholdAudit

    FIELDS_TO_EXPORT = [
        'id',
        'dt_created',
        'field_type',
        'template_kind',
        'status',
        'info',
        'model_version',
    ]
    THRESHOLD_AUDITS_FNAME = 'threshold_audits.csv'

    qs = (
        ThresholdAudit.objects.filter(
            dt_created__gt=timezone.now() - timedelta(days=DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS)
        )
        .order_by('-dt_created')
        .values(*FIELDS_TO_EXPORT)
    )

    write_csv(THRESHOLD_AUDITS_FNAME, FIELDS_TO_EXPORT, qs)


@continue_on_exception
@django_ctx
def capture_machine_audit_logs():
    from django.utils import timezone
    from activity.models import AuditLog

    FIELDS_TO_EXPORT = [
        'id',
        'activity_created',
        'activity_subtype_name',
        'activity_name',
        'object_id',
        'object_type',
        'object_name',
        'changes',
    ]
    COLUMN_FIELDS_TO_EXPORT = ['column_name', 'old_value', 'new_value']

    def get_data():
        qs = (
            AuditLog.objects.filter(
                activity_created__gt=timezone.now()
                - timedelta(days=DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS),
                operator=AuditLog.MACHINE_OPERATOR,
            )
            .prefetch_related('column_changes')
            .order_by('-activity_created')
            .only(*FIELDS_TO_EXPORT)
        )

        for r in qs:
            ret = {f: getattr(r, f) for f in FIELDS_TO_EXPORT}
            column_changes = []
            for cc in r.column_changes.all():
                column_changes.append([getattr(cc, f) for f in COLUMN_FIELDS_TO_EXPORT])
            ret['column_changes'] = json.dumps(column_changes)
            yield ret

    MACHINE_AUDIT_LOG_FNAME = 'machine_audit_log.csv'
    write_csv(MACHINE_AUDIT_LOG_FNAME, FIELDS_TO_EXPORT + ['column_changes'], get_data())


@continue_on_exception
@django_ctx
def capture_attached_trainers():
    from trainer.client.models import Trainer

    FIELDS_TO_EXPORT = [
        # TODO: has_recent_heartbeat available in >R29
        'uuid',
        'version',
        'status',
        'heartbeat',
    ]
    TRAINER_FNAME = 'trainer.csv'

    trainers = Trainer.objects.values(*FIELDS_TO_EXPORT)

    write_csv(TRAINER_FNAME, FIELDS_TO_EXPORT, trainers.all())


@continue_on_exception
@django_ctx
def capture_latest_trainer_runs():
    from django.utils import timezone
    from trainer.client.models import TrainerTask

    FIELDS_TO_EXPORT = [
        'dt_created',
        'uuid',
        'task_handler_type',
        'status',
        'outcome',
        'dt_started',
        'dt_finished',
        'trainer_id',
        'status_info',
    ]
    TRAINER_TASKS_FNAME = 'trainer_tasks.csv'

    trainer_tasks = (
        TrainerTask.objects.filter(
            dt_created__gt=timezone.now() - timedelta(days=DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS)
        )
        .order_by('dt_created')
        .values(*FIELDS_TO_EXPORT)
    )

    write_csv(TRAINER_TASKS_FNAME, FIELDS_TO_EXPORT, trainer_tasks)


@continue_on_exception
@django_ctx
def capture_latest_jobs():
    from django.utils import timezone
    from rest_framework import serializers

    from form_extraction.serializers import JobListSerializer
    from form_extraction.views import ExtractionJobQueueViewSet

    # Bypasses unnecessary add_submission_id calls to speed things up
    # submission_id should be derived from job.task or the job's payload in most cases
    JobListSerializer.to_representation = serializers.ListSerializer.to_representation

    JOBS_FNAME_FMT = 'jobs_%s.json'
    JOBS_PERIOD_IN_DAYS = int(WORKFLOW_EXPORT_PERIOD_IN_SECS / (24 * 60 * 60) + 1)

    serializer_class = ExtractionJobQueueViewSet.serializer_class
    # Dummy object so we can use annotate_queryset in a backwards-compatible way
    # Not needed for pre-R31
    # After R31 this is a staticmethod and we probably won't have jobs anymore anyways
    serializer = serializer_class()
    jobs_qs = serializer.annotate_queryset(ExtractionJobQueueViewSet.queryset)

    abs_beg = WORKFLOW_EXPORT_LATEST_DT - timedelta(seconds=WORKFLOW_EXPORT_PERIOD_IN_SECS)
    created_beg = max(WORKFLOW_EXPORT_LATEST_DT - timedelta(days=1), abs_beg)
    created_end = WORKFLOW_EXPORT_LATEST_DT

    start = time.time()
    for i in range(JOBS_PERIOD_IN_DAYS):
        jobs_list = ExtractionJobQueueViewSet.serializer_class(
            jobs_qs.filter(created__gte=created_beg, created__lt=created_end), many=True
        ).data
        for job in jobs_list:
            del job['payload']
        write_json(JOBS_FNAME_FMT % i, jobs_list)
        created_end = created_beg
        created_beg = max(created_beg - timedelta(days=1), abs_beg)

        if time.time() - start > MAX_WORKFLOW_DOWNLOAD_SECONDS:
            logger.info('Reached MAX_WORKFLOW_DOWNLOAD_SECONDS')
            break


@continue_on_exception
@django_ctx
def capture_connector_logs():
    from django.apps import apps

    if apps.is_installed('connector'):
        from connector.serializers import ConnectorLogSerializer
        from connector.views import ConnectorLogViewset
        from connector.models import ConnectorLog

        CONNECTOR_LOGS_FNAME = 'connector_logs.json'
        CONNECTOR_LOGS_PERIOD_IN_DAYS = DATA_EXPORT_DEFAULT_PERIOD_IN_DAYS

        connector_logs = ConnectorLogViewset.queryset.filter(
            dt_created__gte=datetime.today() - timedelta(days=CONNECTOR_LOGS_PERIOD_IN_DAYS)
        )

        # TODO: json or csv?
        # TODO: Split up
        serializer = ConnectorLogViewset.serializer_class(connector_logs, many=True)

        write_json(CONNECTOR_LOGS_FNAME, serializer.data)


@continue_on_exception
@django_ctx
def capture_configs():
    # TODO: Most of these are already covered in settings export with minor differences.
    # Should we combine them? This is more "raw"
    from form_extraction.settings.views import _get_current_configs

    # These are new
    from common.models import FreeformConfig
    from form_extraction.models import VpcConfig

    CONFIGS_FNAME = 'configs.json'
    FREEFORM_CONFIGS_FNAME = 'freeform_configs.json'
    VPC_CONFIGS_FNAME = 'vpc_configs.json'

    vpc_config = VpcConfig.get_config()

    write_json(CONFIGS_FNAME, _get_current_configs())
    write_json(FREEFORM_CONFIGS_FNAME, dict(FreeformConfig.get_config().config))
    write_json(VPC_CONFIGS_FNAME, vpc_config.get_config_dict())


@continue_on_exception
@django_ctx
def capture_init_entries():
    from init.models import InitEntry

    FIELDS_TO_EXPORT = ['pk', 'dt_created', 'git_hash', 'dotenv_hash']
    ROW_LIMIT = 1000
    INIT_ENTRY_FNAME = 'init_entries.csv'

    init_entries = InitEntry.objects.order_by('-dt_created').values(*FIELDS_TO_EXPORT)

    write_csv(INIT_ENTRY_FNAME, FIELDS_TO_EXPORT, init_entries.all()[:ROW_LIMIT])


@continue_on_exception
@django_ctx
def capture_health_records():
    from common.models import HealthRecord

    FIELDS_TO_EXPORT = ['healthy', 'dt_created', 'dt_updated', 'hostname', 'status']
    HEALTH_RECORD_FNAME = 'health_records.csv'

    health_records = HealthRecord.objects.values(*FIELDS_TO_EXPORT)

    write_csv(HEALTH_RECORD_FNAME, FIELDS_TO_EXPORT, health_records.all())


@continue_on_exception
@django_ctx
def capture_health_statistics_records():
    from common.models import HealthStatisticsRecord
    from django.utils import timezone

    FIELDS_TO_EXPORT = ['dt_created', 'statistics']
    HEALTH_STATISTICS_RECORD_FNAME = 'health_statistics_records.csv'
    # Each record contains info for the past 60 minutes, and past 24 hours
    # Records are written every 10 minutes

    health_statistics_records = (
        HealthStatisticsRecord.objects.filter(
            dt_created__gte=WORKFLOW_EXPORT_LATEST_DT - timedelta(seconds=WORKFLOW_EXPORT_PERIOD_IN_SECS),
            dt_created__lt=WORKFLOW_EXPORT_LATEST_DT
        )
        .order_by('-dt_created')
        .values(*FIELDS_TO_EXPORT)
    )

    write_csv(HEALTH_STATISTICS_RECORD_FNAME, FIELDS_TO_EXPORT, health_statistics_records[:500])


@continue_on_exception
@django_ctx
def capture_workflow_instances():
    from sdm.utils import timestamp_to_string
    from sdm.wfe.proxy import WorkflowEngineProxy
    from hyperflow.models import WfeWorkflowInstance
    from django.utils import timezone

    # Copied from WorkflowJobViewSet json_download
    WORKFLOW_DOWNLOAD_FIELDS = [
        'createTime',
        'updateTime',
        'status',
        'reasonForIncompletion',
        'endTime',
        'workflowId',
        'workflowType',
        'version',
        'correlationId',
        'schemaVersion',
        'workflowDefinition',
        'priority',
        'startTime',
        'workflowName',
        'workflowVersion',
        'ownerApp',
        'taskToDomain',
        'failedReferenceTasknames',
    ]
    TASK_DOWNLOAD_FIELDS = [
        'taskType',
        'status',
        'referenceTaskName',
        'workflowInstanceId',
        'taskId',
        'workerId',
        'priority',
        'workflowTask',
        'taskDefName',
        'correlationId',
        'scheduledTime',
        'startTime',
        'endTime',
        'reasonForIncompletion',
    ]
    TASK_DOWNLOAD_TIME_FIELDS = ['scheduledTime', 'startTime', 'endTime']

    def get_workflows_json(correlation_id):
        sem.acquire()
        try:
            unique_dsls = {}
            wfis = []
            workflow_ids = list(WfeWorkflowInstance.objects.filter(
                correlation_id=correlation_id
            ).values_list('uuid', flat=True))
            for workflow_id in workflow_ids:
                try:
                    wf_details = WorkflowEngineProxy.get_workflow_run(workflow_id)
                except HTTPError:
                    logger.error('Failed to retrieve workflow: {}', workflow_id)
                    continue

                wf_row: Dict[str, Any] = {}
                if not CAPTURE_PII:
                    for field in WORKFLOW_DOWNLOAD_FIELDS:
                        wf_row[field] = wf_details.get(field)
                    wf_row['tasks'] = []
                    for task in wf_details['tasks']:
                        task_details = {}
                        for field in TASK_DOWNLOAD_FIELDS:
                            task_details[field] = task.get(field)
                        for field in TASK_DOWNLOAD_TIME_FIELDS:
                            task_details[field] = timestamp_to_string(task.get(field))
                        subworkflow_id = task['inputData'].get('subWorkflowId', None)
                        if subworkflow_id:
                            task_details['inputData'] = {'subWorkflowId': subworkflow_id}
                        forked_tasks = task['inputData'].get('forkedTasks', None)
                        if forked_tasks:
                            task_details['inputData'] = {
                                **task_details.get('inputData', {}),
                                'forkedTasks': forked_tasks,
                            }

                        wf_row['tasks'].append(task_details)
                else:
                    wf_row = wf_details
                # Store DSLs separately to dedupe and reduce output size
                hash_key = (
                    wf_row['workflowDefinition']['name'],
                    wf_row['workflowDefinition']['version'],
                )
                if hash_key not in unique_dsls:
                    unique_dsls[hash_key] = copy.deepcopy(wf_row['workflowDefinition'])
                del wf_row['workflowDefinition']['tasks']

                wfis.append(wf_row)

            return wfis, unique_dsls
        except:
            logger.exception('Failed to fetch WFs...')
            return [], {}

    # Write every PAGE_SIZE to one file
    PAGE_SIZE = 5000
    FILE_NAME = 'wfis_%s.json'
    DSL_FILE_NAME = 'wf_dsls.json'
    # Number of concurrent WFIs pages to process
    # Don't take up too much CPU
    THREADS = os.cpu_count() / 2
    # Limits the number of concurrently *fetched* WFI pages to
    # avoid keeping too many WFIs in memory
    sem = threading.Semaphore(value=THREADS * 2)

    futures = []
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        # Incomplete flows could be interesting, so let's make sure we have some of them.
        incomplete_correlation_ids = list(
            WfeWorkflowInstance.objects.filter(
                dt_started__gte=WORKFLOW_EXPORT_LATEST_DT
                - timedelta(seconds=WORKFLOW_EXPORT_PERIOD_IN_SECS),
                dt_started__lt=WORKFLOW_EXPORT_LATEST_DT,
            )
            .exclude(status=WfeWorkflowInstance.STATUS_COMPLETED)
            .values('correlation_id')
            .annotate(last_execution=Max('dt_started'))
            .order_by('-last_execution')
            .values_list('correlation_id', flat=True)
            .distinct()[:DISTINCT_CORRELATION_IDS_LIMIT]
        )

        all_correlation_ids = list(
            WfeWorkflowInstance.objects.filter(
                dt_started__gte=WORKFLOW_EXPORT_LATEST_DT
                - timedelta(seconds=WORKFLOW_EXPORT_PERIOD_IN_SECS),
                dt_started__lt=WORKFLOW_EXPORT_LATEST_DT,
            )
            .values('correlation_id')
            .annotate(last_execution=Max('dt_started'))
            .order_by('-last_execution')
            .values_list('correlation_id', flat=True)
            .distinct()[:DISTINCT_CORRELATION_IDS_LIMIT]
        )

        correlation_ids = []
        correlation_ids_set = set()
        # Add in alternating fashion
        for pair in itertools.zip_longest(incomplete_correlation_ids, all_correlation_ids):
            for correlation_id in pair:
                if len(correlation_ids) >= DISTINCT_CORRELATION_IDS_LIMIT:
                    break
                if not correlation_id or correlation_id in correlation_ids_set:
                    continue
                correlation_ids.append(correlation_id)
                correlation_ids_set.add(correlation_id)

        logger.info(f'Found {len(correlation_ids)} correlation_ids')

        for correlation_id in correlation_ids:
            futures.append(executor.submit(get_workflows_json, correlation_id))

        current_file_wfis_count = 0
        file_count = 0
        found_wf_dsls = {}
        try:
            current_file = File(FILE_NAME % file_count)
            current_file.write('[\n')
            first = True
            start = time.time()
            for future in as_completed(futures):
                wfis, wf_dsls = future.result()
                found_wf_dsls.update(wf_dsls)
                for wfi in wfis:
                    if not first:
                        current_file.write(',\n')
                    current_file.write(json.dumps(wfi, indent=3))
                    first = False
                current_file_wfis_count += len(wfis)
                if current_file_wfis_count > PAGE_SIZE:
                    current_file.write('\n]')
                    current_file.complete()
                    first = True
                    file_count += 1
                    current_file = File(FILE_NAME % file_count)
                    current_file.write('[\n')
                    current_file_wfis_count = 0
                # Explicitly clear the wfis dict, otherwise
                # futures still hold onto these objects and prevent
                # GC from freeing
                wfis.clear()
                sem.release()

                if time.time() - start > MAX_WORKFLOW_DOWNLOAD_SECONDS:
                    logger.info('Reached MAX_WORKFLOW_DOWNLOAD_SECONDS')
                    for future in futures:
                        future.cancel()
                    break

            current_file.write('\n]')
            current_file.complete()
        except:
            # Complete current_file otherwise script will be stuck
            current_file.complete()
            raise
        if found_wf_dsls:
            write_json(DSL_FILE_NAME, list(found_wf_dsls.values()))


@continue_on_exception
@django_ctx
def capture_workflow_dsls():
    from sdm.wfe.proxy import WorkflowEngineProxy

    write_json('current_wf_dsls.json', WorkflowEngineProxy.list_workflow_definitions())


def _raw_to_dict(cursor, query, header=None):
    cursor.execute(query)
    raw_rows = cursor.fetchall()
    if header is None:
        header = [col[0] for col in cursor.description]

    return header, [dict(zip(header, row)) for row in raw_rows]


# NB:
# https://sqlsunday.com/2014/10/05/viewing-size-of-database-objects/
# The above seems to be a more detailed query, but requires additional permissions
# whereas the sys.partitions and sys.allocation_units tables are public.
def _get_db_size_mssql(cursor):
    # https://docs.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-partitions-transact-sql?view=sql-server-ver15
    query = '''
SELECT object_name(p.object_id) AS ObjectName,
sum(total_pages / 128.) AS SpaceUsed_MB,
p.partition_id,
p.object_id,
p.index_id,
p.partition_number,
p.rows,
p.data_compression_desc,
p.index_id,
i.index_id,
case
    when p.index_id < 1 then 'heap'
    else i.name
end as Index_Name,
case
    when p.index_id = 1 then 'table'
    else 'index'
end as Type
FROM sys.partitions AS p
JOIN sys.allocation_units AS au ON p.partition_id = au.container_id
LEFT JOIN sys.indexes i on p.object_id = i.object_id and p.index_id = i.index_id
GROUP BY p.partition_id, p.object_id, p.index_id, p.partition_number, p.rows, p.data_compression_desc, p.index_id, i.index_id, i.name
ORDER BY ObjectName ASC, SpaceUsed_MB DESC
'''
    write_csv('obj_size.csv', *_raw_to_dict(cursor, query))

    query = '''
SELECT object_name(p.object_id) AS ObjectName,
au.total_pages / 128. AS SpaceUsed_MB,
case
    when p.index_id = 1 then 'table'
    else 'index'
end as Type,
case
    when p.index_id < 1 then 'heap'
    else i.name
end as Index_Name,
case
    when au.[type] = 0 then 'Dropped'
    when au.[type] = 1 then 'In-row data'
    when au.[type] = 2 then 'LOB'
    when au.[type] = 3 then 'Row-overflow'
    else 'unknown'
end as AU_Type,
p.rows,
p.partition_id,
p.object_id,
p.index_id,
p.partition_number,
p.data_compression_desc,
au.[type] as AU_Type_Numeric,
case
    when p.index_id < 1 then 'heap'
    else i.name
end as Index_Name,
case
    when p.index_id = 1 then 'table'
    else 'index'
end as Type
FROM sys.partitions AS p
left JOIN sys.allocation_units AS au ON p.partition_id = au.container_id
left join sys.indexes i on p.object_id = i.object_id and p.index_id = i.index_id
ORDER BY ObjectName asc;
'''
    write_csv('obj_overflow.csv', *_raw_to_dict(cursor, query))

    # https://www.mssqltips.com/sqlservertip/2537/sql-server-row-count-for-all-tables-in-a-database/
    query = '''
SELECT QUOTENAME(SCHEMA_NAME(sobj.schema_id)) + '.' + QUOTENAME(sobj.name),
SUM(spart.Rows) as cnt
FROM sys.objects AS sobj
INNER JOIN sys.partitions AS spart
ON sobj.object_id = spart.object_id
WHERE sobj.type = 'U'
AND sobj.is_ms_shipped = 0x0
AND index_id < 2 -- 0:Heap, 1:Clustered
GROUP BY sobj.schema_id, sobj.name
ORDER BY cnt DESC
'''
    header = ['Table Name', 'Row Count']
    write_csv('row_counts.csv', *_raw_to_dict(cursor, query, header))

    query = '''
DBCC SQLPERF(logspace)
'''
    header = ['Database Name', 'Log Size (MB)', 'Log Space Used (%)', 'Status']
    write_csv('tx_log.csv', *_raw_to_dict(cursor, query, header))


def _get_db_size_oracle(cursor):
    query = '''
SELECT segment_name, SUM(bytes)/1024/1024 AS sz
FROM user_segments
WHERE segment_type='TABLE'
GROUP BY segment_name
ORDER BY sz DESC
'''
    header = ['Table Name', 'Size (MB)']
    write_csv('table_size.csv', *_raw_to_dict(cursor, query, header))

    query = '''
SELECT idx.table_name, idx.index_name, SUM(bytes)/1024/1024 AS sz
FROM user_segments seg,
    user_indexes idx
WHERE idx.index_name  = seg.segment_name
GROUP BY idx.index_name, idx.table_name
ORDER BY sz DESC
'''
    header = ['Table Name', 'Index Name', 'Size (MB)']
    write_csv('index_size.csv', *_raw_to_dict(cursor, query, header))

    query = '''
SELECT table_name, NUM_ROWS FROM USER_TABLES
ORDER BY NUM_ROWS DESC
'''
    header = ['Table Name', 'Row Count']
    write_csv('row_counts.csv', *_raw_to_dict(cursor, query, header))

    # NB: bash magic. Can't put them on a single line otherwise bash tries to resolve this
    # to a variable
    query = '''
SELECT *
FROM V$'''
    query += 'LOG'
    write_csv('tx_log.csv', *_raw_to_dict(cursor, query))


def _get_db_size_postgres(cursor):
    query = '''
SELECT
    c1.relname,
    pg_size_pretty(pg_total_relation_size(c1.relname::regclass)) AS total_size,
    pg_size_pretty(pg_relation_size(c1.relname::regclass)) AS relation_main_size,
    pg_size_pretty(pg_table_size(c1.relname::regclass)) AS table_size,
    pg_size_pretty(pg_indexes_size(c1.relname::regclass)) AS index_size,
    pg_stat_get_live_tuples(c1.oid) AS n_live_tup,
    pg_stat_get_dead_tuples(c1.oid) AS n_dead_tup,
    pg_size_pretty(pg_relation_size(c1.reltoastrelid)) AS toast_size,
    pg_stat_get_live_tuples(c1.reltoastrelid) AS n_toast_live_tup,
    pg_stat_get_dead_tuples(c1.reltoastrelid) AS n_toast_dead_tup
FROM
    pg_class c1
    INNER JOIN pg_namespace N ON (N.oid = c1.relnamespace)
    INNER JOIN pg_stat_user_tables S ON (S.relname = c1.relname)
WHERE
    nspname NOT IN ('pg_catalog', 'information_schema') AND
    c1.relkind = 'r'
ORDER BY pg_relation_size(c1.relname::regclass) + Coalesce(pg_relation_size(c1.reltoastrelid), 0) DESC
'''
    write_csv('table_size.csv', *_raw_to_dict(cursor, query))

    # https://stackoverflow.com/questions/7943233/fast-way-to-discover-the-row-count-of-a-table-in-postgresql
    query = '''
SELECT c.relname as table_name, (CASE WHEN c.reltuples < 0 THEN NULL       -- never vacuumed
             WHEN c.relpages = 0 THEN float8 '0'                		   -- empty table
             ELSE c.reltuples / c.relpages END
      * (pg_relation_size(c.oid) / pg_catalog.current_setting('block_size')::int)
       )::bigint as row_count
FROM
	pg_class c
    INNER JOIN pg_namespace N ON (N.oid = c.relnamespace)
    INNER JOIN pg_stat_user_tables S ON (S.relname = c.relname)
WHERE c.relkind = 'r'
ORDER BY row_count DESC
'''
    write_csv('row_counts.csv', *_raw_to_dict(cursor, query))

    query = '''
select pg_size_pretty(sum(size)) as total_wal_size
from pg_ls_waldir()
'''
    write_csv('wal_size.csv', *_raw_to_dict(cursor, query))


@continue_on_exception
def get_db_size(cursor):
    from django.db import connection

    if connection.vendor == 'microsoft':
        _get_db_size_mssql(cursor)
    elif connection.vendor == 'oracle':
        _get_db_size_oracle(cursor)
    else:
        _get_db_size_postgres(cursor)


def _get_db_info_mssql(cursor):
    query = '''
SELECT @@VERSION as Version, cpu_count, physical_memory_kb / 1024 / 1024 mem_gb
FROM sys.dm_os_sys_info;
'''
    header = ['Version', 'CPU (w/HT) Count', 'Memory (GB)']
    write_csv('db_info.csv', *_raw_to_dict(cursor, query, header))

    query = '''
SELECT *
FROM sys.databases;
'''
    write_csv('db_params.csv', *_raw_to_dict(cursor, query))


def _get_db_info_oracle(cursor):
    query = '''
SELECT * FROM v$'''
    # NB: bash magic. Can't put them on a single line otherwise bash tries to resolve this
    # to a variable
    query += 'version'
    write_csv('db_info.csv', *_raw_to_dict(cursor, query))

    query = '''
SELECT *
FROM V$'''
    # See above
    query += 'PARAMETER'
    write_csv('db_params.csv', *_raw_to_dict(cursor, query))


# NB: Postgres doesn't have a way to extract core count or total RAM
def _get_db_info_postgres(cursor):
    query = '''
select version();
'''
    write_csv('db_version.csv', *_raw_to_dict(cursor, query))

    query = '''
select * from pg_stat_activity
order by now() - pg_stat_activity.query_start;
'''
    write_csv('query_activity.csv', *_raw_to_dict(cursor, query))

    query = '''
show all;
'''
    write_csv('db_params.csv', *_raw_to_dict(cursor, query))


@continue_on_exception
def get_db_info(cursor):
    from django.db import connection

    if connection.vendor == 'microsoft':
        _get_db_info_mssql(cursor)
    elif connection.vendor == 'oracle':
        _get_db_info_oracle(cursor)
    else:
        _get_db_info_postgres(cursor)


@continue_on_exception
@django_ctx
def capture_db_info():
    from django.db import connection

    with connection.cursor() as cursor:
        get_db_size(cursor)
        get_db_info(cursor)

EOM

####################################################################################
#              Python code ends
####################################################################################

main
