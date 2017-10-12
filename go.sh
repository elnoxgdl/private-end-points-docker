#!/bin/bash -u

# Initialize and run an Encrypt.me private end-point via Docker

# TODO: integrate whether or not to collect stats
# TODO: implement comodo SSL certs


BASE_DIR=$(cd $(dirname "$0") && pwd -P)
SCRIPT_NAME=$(basename "$0")

[ $UID -eq 0 ] && conf_dir=/etc/encryptme || conf_dir="$BASE_DIR/encryptme_conf"
user_email=
user_pass=
server_name=
target_id=
action=
pull_image=0
auto_update=0
send_stats=0
api_url=
dns_check=0
dryrun=0
retry=0
verbose=0
restart=0
cert_type="letsencrypt"
docker_img="royhooper/encryptme-server"  # TODO: finalize w/ Encryptme hub account
stats_img="royhooper/encryptme-stats"  # TODO: finalize w/ Encryptme hub account
wt_image="v2tec/watchtower"
name="encryptme"


usage() {
    cat << EOF
usage: $0 ACTION [ACTION ARGS]

  Initialize an Encrypt.me private-end point server from a Docker image. Run
  './go.sh init' and then './go.sh run' to set everything up. Any missing
  parameters (email, pass, target for init; email only for run) will be
  prompted for if missing.


ACTIONS:

    init    initialize a docker container and register this server
    run     set the private-end point to run
    clean   remove the private end-point container, images, and configs
    reset   stop/remove any current instance and remove configs


GENERIC OPTIONS:
    --remote hostname     SSH to this [user@]hostname and run this scrip there
    -c|--conf-dir DIR     Directory to use/create for private configs/certs
    -d|--dryrun|--dry-run Run without making changes
                          (default: $conf_dir)
    -e|--email            Your Encrypt.me email address (for certs/API auth)
    -h|--help             Show this message
    -i|--image IMAGE      Docker image to use (default: $docker_img)
    -n|--name NAME        Container name (default: $name)
    -D|--dns-check        Attempt to do AWS/DO DNS validation
    -t|--cert-type TYPE   Certificate type to use e.g. 'letsencypt', 'comodo' (default: $cert_type)
    -v|--verbose          Verbose debugging info

INIT OPTIONS:
    --server-name FQDN    Fully-qualified domain name for this VPN end-point
    --target-id ID        Target ID for end-point in Encrypt.me UI
    --user-pass PASS      Your Encrypt.me password
    --retry               Retry with an existing container
    --api-url URL         Use custom URL for Encrypt.me server API

RUN OPTIONS:
    -R|--restart          Restarts running services if already running

PRIVACY/SECURITY OPTIONS:
    -P|--pull-image       Pull Docker Hub image? (default: off)
    -U|--update           Run WatchTower to keep VPN container up-to-date (default: off)
    -S|--stats            Send generic bandwidth/health stats (default: off)


EXAMPLES:

    # launch an auto-updating image with health reporting using the official image and ensure our AWS/DO public IP matches our FQDN
    ./go.sh init -S -U -P -D
    
    # run the newly initialized server
    ./go.sh run

EOF
}

fail() {
    echo "! $1" >&2
    exit 1
}

rem() {
    [ "$verbose" -eq 1 ] && echo "+ [$@]" >&2
}

cmd() {
    local retval=0
    if [ $dryrun -eq 1 ]; then
        echo "# $@"
    else
        [ $verbose -eq 1 ] && echo "$   $@" >&2
        "$@"
        retval=$?
    fi
    return $retval
}

collect_args() {
    while [ -z "$user_email" ]; do
        read -p "Enter your Encrypt.me email address: " user_email
    done
    [ "$action" = 'init' ] && {
        while [ -z "$user_pass" ]; do
            read -p "Enter your Encrypt.me password: " -s user_pass
        done
        while [ -z "$target_id" ]; do
            read -p $'\n'"Enter your Encrypt.me target ID: " target_id
        done
        while [ -z "$server_name" ]; do
            read -p "Enter your Encrypt.me endpoint FQDN: " server_name
        done
    }
}

docker_cleanup() {
    running=$(cmd docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null)
    rem "Container '$1' has running=$running"
    [ $restart -eq 1 -a "$running" = "true" ] &&
        (docker kill "$1" ||
            fail "Failed to kill running container $1")
    [ $restart -eq 1 -a ! -z "$running" ] &&
        (docker rm "$1" ||
            fail "Failed to remove container $1")
}

server_init() {
    docker_cleanup "$name"
    cmd docker run --rm -it --name "$name" \
        -e ENCRYPTME_EMAIL="$user_email" \
        -e ENCRYPTME_PASSWORD="$user_pass" \
        -e ENCRYPTME_TARGET_ID="$target_id" \
        -e ENCRYPTME_API_URL="$api_url" \
        -e ENCRYPTME_SERVER_NAME="$server_name" \
        -e ENCRYPTME_VERBOSE=$verbose \
        -e ENCRYPTME_INIT_ONLY=1 \
        -e ENCRYPTME_DNS_CHECK=$dns_check \
        -v "$conf_dir:/etc/encryptme" \
        -v "$conf_dir/letsencrypt:/etc/letsencrypt" \
        -v /lib/modules:/lib/modules \
        --privileged \
        --net host \
        "$docker_img"
}

server_watch() {
    docker_cleanup "watchtower"
    cmd docker run -d \
       --name watchtower \
       -v /var/run/docker.sock:/var/run/docker.sock \
       "$wt_image"
}


server_stats() {
    docker_cleanup "encryptme-stats"
    cmd docker run -d \
        --name encryptme-stats \
        -v /proc:/hostfs/proc:ro \
        -v /sys/fs/cgroup:/hostfs/sys/fs/cgroup:ro \
        -v /:/hostfs:ro \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$conf_dir:/etc/encryptme" \
        --net host \
        "$stats_img"
}

server_run() {
    docker_cleanup "$name"
    cmd docker run -d --name "$name" \
        -e ENCRYPTME_EMAIL="$user_email" \
        -e ENCRYPTME_VERBOSE=$verbose \
        -e ENCRYPTME_DNS_CHECK=$dns_check \
        -v "$conf_dir:/etc/encryptme" \
        -v "$conf_dir/letsencrypt:/etc/letsencrypt" \
        -v /lib/modules:/lib/modules \
        --privileged \
        --net host \
        --restart always \
        "$docker_img"
}

server_reset() {
    docker_cleanup "$name"
    docker_cleanup "$wt_image"
    docker_cleanup "$stats_img"
    cmd rm -rf "$conf_dir"
}

server_cleanup() {
    server_reset
    cmd docker rmi "$docker_img"
    cmd docker rmi "$wt_image"
    cmd docker rmi "$stats_img"
}


# gather up args
while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in 
        --dryrun|dry-run|-d)
            dryrun=1
            ;;
        --conf-dir|-c)
            [ $# -ge 1 ] || fail "Missing arg to --conf-dir|-c"
            conf_dir="$1"
            shift
            ;;
        --help|-h)
            usage
            exit
            ;;
        --image|-i)
            [ $# -ge 1 ] || fail "Missing arg to --image|-i"
            docker_img="$1"
            shift
            ;;
        --email|-e)
            [ $# -ge 1 ] || fail "Missing arg to --email|-e"
            user_email="$1"
            shift
            ;;
        --user-pass)
            [ $# -ge 1 ] || fail "Missing arg to --user-pass"
            user_pass="$1"
            shift
            ;;
        --target-id)
            [ $# -ge 1 ] || fail "Missing arg to --target-id"
            target_id="$1"
            shift
            ;;
        --server-name)
            [ $# -ge 1 ] || fail "Missing arg to --server_name"
            server_name="$1"
            shift
            ;;
        --cert-type)
            [ $# -ge 1 ] || fail "Missing arg to --cert-type"
            cert_type="$1"
            shift
            [ "$cert_type" = 'comodo' ] \
                && fail "TODO: implement using comodo"
            ;;
        --api-url)
            [ $# -ge 1 ] || fail "Missing arg to --url"
            api_url="$1"
            shift
            ;;
        --dns-check|-D)
            dns_check=1
            ;;
        --update|-U)
            auto_update=1
            # TODO ensure auto-update works w/ locally built images
            ;;
        --pull-image|-P)
            pull_image=1
            ;;
        --stats|-S)
            send_stats=1
            ;;
        --verbose|-v)
            verbose=1
            ;;
        --remote)
            remote_host="$1"
            shift
            scp -q "$0" "$remote_host":go.sh \
                || fail "Couldn't copy script to $remote_host"
            ssh -qt "$remote_host" ./go.sh "$@" \
                || fail "Remote on $remote_host execution failed"
            ssh -q "$remote_host" rm go.sh \
                || fail "Failed to remove go.sh from $remote_host"
            exit
            ;;
        --restart)
            restart=1
            ;;
        *)
            [ -n "$action" ] && fail "Invalid arg '$arg'; an action of '$action' was already given"
            action="$arg"
            ;;
    esac
done


# setup for run
# --------------------------------------------------
# a few sanity checks
[ $dryrun -eq 1 ] && echo "# DRY-RUN" >&2
cmd which docker > /dev/null || fail "Docker is not installed"
case "$action" in
    init|run|clean|reset)
        ;;
    *)
        fail "Invalid action: '$action'"
esac
[ "$cert_type" = 'comodo' -o "$cert_type" = 'letsencrypt' ] \
    || fail "Invalid certificate type: $cert_type"

# init/run pre-tasks
[ "$action" = 'init' -o "$action" = 'run' ] && {
    # the images exist? auto-pull latest if using the official image
    rem "pulling '$docker_img' from Docker Hub"
    [ $pull_image -eq 1 ] && {
        cmd docker pull "$docker_img" \
            || fail "Failed to pull '$docker_img' from Docker Hub"
    }
    # now do all image images we need exist?
    docker_img_id=$(cmd docker images -q "$docker_img")
    [ -n "$docker_img_id" ] \
        || fail "No docker image named '$docker_img' found; either build the image or use --pull-image to pull the image from Docker Hub"

    [ $pull_image -eq 1 -a $auto_update -eq 1 ] \
        && cmd docker pull "$wt_image" \
            || fail "Failed to pull '$wt_image' from Docker Hub"

    [ $pull_image -eq 1 -a $send_stats -eq 1 ] \
        && cmd docker pull "$stats_img" \
            || fail "Failed to pull '$stats_img' from Docker Hub"

    # get auth/server info if needed
    rem "interactively collecting any required missing params"
    collect_args
}


# perform the main action
# --------------------------------------------------
[ "$action" = "init" ] && {
    rem "starting $name container to run config initialization"
    server_init || fail "Docker container and/or Encrypt.me private end-point failed to initialize"
}

[ "$action" = "run" ] && {
    [ $auto_update -eq 1 ] && {
        server_watch || fail "Failed to start Docker watchtower"
    }
    [ $send_stats -eq 1 ] && {
        server_stats || fail "Failed to start Docker encryptme-stats"
    }
    rem "starting $name container"
    server_run || fail "Failed to start Docker container for Encrypt.me private end-point"
}

[ "$action" = "reset" ] && {
    rem "cleaning up traces of $name container and configs"
    server_reset
}

[ "$action" = "clean" ] && {
    rem "cleaning up all traces of $name container, images, and configs"
    server_cleanup
}

exit 0