#!/bin/sh
set -e

[ -n "$WEAVE_DEBUG" ] && set -x

SCRIPT_VERSION="1.9.8"
IMAGE_VERSION=latest
[ "$SCRIPT_VERSION" = "unreleased" ] || IMAGE_VERSION=$SCRIPT_VERSION
IMAGE_VERSION=${WEAVE_VERSION:-$IMAGE_VERSION}

# - The weavexec image embeds a Docker 1.10.3 client. Docker will give
#   a "client is newer than server error" if the daemon has an older
#   API version, which could be confusing if the user's Docker client
#   is correctly matched with that older version.
#
# We therefore check that the user's Docker *client* is >= 1.10.3
MIN_DOCKER_VERSION=1.10.0

# These are needed for remote execs, hence we introduce them here
DOCKERHUB_USER=${DOCKERHUB_USER:-weaveworks}
BASE_EXEC_IMAGE=$DOCKERHUB_USER/weaveexec
EXEC_IMAGE=$BASE_EXEC_IMAGE:$IMAGE_VERSION
WEAVEDB_IMAGE=$DOCKERHUB_USER/weavedb
PROXY_HOST=${PROXY_HOST:-$(echo "${DOCKER_HOST#tcp://}" | cut -s -d: -f1)}
PROXY_HOST=${PROXY_HOST:-127.0.0.1}
DOCKER_CLIENT_HOST=${DOCKER_CLIENT_HOST:-$DOCKER_HOST}

# Define some regular expressions for matching addresses.
# The regexp here is far from precise, but good enough.
IP_REGEXP="[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"
CIDR_REGEXP="$IP_REGEXP/[0-9]{1,2}"

######################################################################
# helpers that run locally, even without --local
######################################################################

usage_no_exit() {
    cat >&2 <<EOF
Usage:

weave --help | help
      setup
      version

weave launch        <same arguments as 'weave launch-router'>
      launch-router [--password <pass>] [--trusted-subnets <cidr>,...]
                      [--host <ip_address>]
                      [--name <mac>] [--nickname <nickname>]
                      [--no-restart] [--resume] [--no-discovery] [--no-dns]
                      [--ipalloc-init <mode>]
                      [--ipalloc-range <cidr> [--ipalloc-default-subnet <cidr>]]
                      [--log-level=debug|info|warning|error]
                      <peer> ...
      launch-proxy  [-H <endpoint>] [--without-dns] [--no-multicast-route]
                      [--no-rewrite-hosts] [--no-default-ipalloc] [--no-restart]
                      [--hostname-from-label <labelkey>]
                      [--hostname-match <regexp>]
                      [--hostname-replacement <replacement>]
                      [--rewrite-inspect]
                      [--log-level=debug|info|warning|error]
      launch-plugin [--no-restart] [--no-multicast-route]
                      [--log-level=debug|info|warning|error]

weave prime

weave env           [--restore]
      config
      dns-args

weave connect       [--replace] [<peer> ...]
      forget        <peer> ...

weave run           [--without-dns] [--no-rewrite-hosts] [--no-multicast-route]
                      [<addr> ...] <docker run args> ...
      start         [<addr> ...] <container_id>
      attach        [<addr> ...] <container_id>
      detach        [<addr> ...] <container_id>
      restart       <container_id>

weave expose        [<addr> ...] [-h <fqdn>]
      hide          [<addr> ...]

weave dns-add       [<ip_address> ...] <container_id> [-h <fqdn>] |
                    <ip_address> ... -h <fqdn>
      dns-remove    [<ip_address> ...] <container_id> [-h <fqdn>] |
                    <ip_address> ... -h <fqdn>
      dns-lookup    <unqualified_name>

weave status        [targets | connections | peers | dns | ipam]
      report        [-f <format>]
      ps            [<container_id> ...]

weave stop
      stop-router
      stop-proxy
      stop-plugin

weave reset         [--force]
      rmpeer        <peer_id> ...


where <peer>     = <ip_address_or_fqdn>[:<port>]
      <cidr>     = <ip_address>/<routing_prefix_length>
      <addr>     = [ip:]<cidr> | net:<cidr> | net:default
      <endpoint> = [tcp://][<ip_address>]:<port> | [unix://]/path/to/socket
      <peer_id>  = <nickname> | <weave internal peer ID>
      <mode>     = consensus[=<count>] | seed=<mac>,... | observer
EOF
}

usage() {
    usage_no_exit
    exit 1
}

handle_help_arg() {
    if [ "$1" = "--help" ] ; then
        usage_no_exit
        exit 0
    fi
}

docker_sock_options() {
    # Pass through DOCKER_HOST if it is a Unix socket;
    # a TCP socket may be secured by TLS, in which case we can't use it
    if echo "$DOCKER_HOST" | grep -q "^unix://" >/dev/null; then
        echo "-v ${DOCKER_HOST#unix://}:${DOCKER_HOST#unix://} -e DOCKER_HOST"
    else
        echo "-v /var/run/docker.sock:/var/run/docker.sock"
    fi
}

docker_run_options() {
    echo --privileged --net=host $(docker_sock_options)
}

exec_options() {
    case "$1" in
        setup|setup-cni|launch|launch-router)
            echo -v /:/host -e HOST_ROOT=/host
            ;;
        # All the other commands that may create the bridge and need machine id files.
        # We don't mount '/' to avoid recursive mounts of '/var'
        create-bridge|attach-router|run|start|attach|restart|expose|hide)
            echo -v /etc:/host/etc -v /var/lib/dbus:/host/var/lib/dbus -e HOST_ROOT=/host
            ;;
    esac
}

exec_remote() {
    docker $DOCKER_CLIENT_ARGS run --rm \
        $(docker_run_options) \
        --pid=host \
        $(exec_options "$@") \
        -e DOCKERHUB_USER="$DOCKERHUB_USER" \
        -e WEAVE_VERSION \
        -e WEAVE_DEBUG \
        -e WEAVE_DOCKER_ARGS \
        -e WEAVEPROXY_DOCKER_ARGS \
        -e WEAVEPLUGIN_DOCKER_ARGS \
        -e WEAVE_PASSWORD \
        -e WEAVE_PORT \
        -e WEAVE_HTTP_ADDR \
        -e WEAVE_STATUS_ADDR \
        -e WEAVE_CONTAINER_NAME \
        -e WEAVE_MTU \
        -e WEAVE_NO_FASTDP \
        -e WEAVE_NO_BRIDGED_FASTDP \
        -e WEAVE_NO_PLUGIN \
        -e DOCKER_BRIDGE \
        -e DOCKER_CLIENT_HOST="$DOCKER_CLIENT_HOST" \
        -e DOCKER_CLIENT_ARGS \
        -e PROXY_HOST="$PROXY_HOST" \
        -e COVERAGE \
        -e CHECKPOINT_DISABLE \
        -e AWSVPC   \
        $WEAVEEXEC_DOCKER_ARGS $EXEC_IMAGE --local "$@"
}

# Given $1 and $2 as semantic version numbers like 3.1.2, return [ $1 < $2 ]
version_lt() {
    VERSION_MAJOR=${1%.*.*}
    REST=${1%.*} VERSION_MINOR=${REST#*.}
    VERSION_PATCH=${1#*.*.}

    MIN_VERSION_MAJOR=${2%.*.*}
    REST=${2%.*} MIN_VERSION_MINOR=${REST#*.}
    MIN_VERSION_PATCH=${2#*.*.}

    if [ \( "$VERSION_MAJOR" -lt "$MIN_VERSION_MAJOR" \) -o \
        \( "$VERSION_MAJOR" -eq "$MIN_VERSION_MAJOR" -a \
        \( "$VERSION_MINOR" -lt "$MIN_VERSION_MINOR" -o \
        \( "$VERSION_MINOR" -eq "$MIN_VERSION_MINOR" -a \
        \( "$VERSION_PATCH" -lt "$MIN_VERSION_PATCH" \) \) \) \) ] ; then
        return 0
    fi
    return 1
}

check_docker_version() {
    if ! DOCKER_VERSION=$(docker -v | sed -n -e 's|^Docker version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*|\1|p') || [ -z "$DOCKER_VERSION" ] ; then
        echo "ERROR: Unable to parse docker version" >&2
        exit 1
    fi

    if version_lt $DOCKER_VERSION $MIN_DOCKER_VERSION ; then
        echo "ERROR: weave requires Docker version $MIN_DOCKER_VERSION or later; you are running $DOCKER_VERSION" >&2
        exit 1
    fi
}

is_cidr() {
    echo "$1" | grep -E "^$CIDR_REGEXP$" >/dev/null
}

collect_cidr_args() {
    CIDR_ARGS=""
    CIDR_ARG_COUNT=0
    while [ "$1" = "net:default" ] || is_cidr "$1" || is_cidr "${1#ip:}" || is_cidr "${1#net:}" ; do
        CIDR_ARGS="$CIDR_ARGS ${1#ip:}"
        CIDR_ARG_COUNT=$((CIDR_ARG_COUNT + 1))
        shift 1
    done
}

dns_arg_count() {
    if [ "$1" = "--with-dns" -o "$1" = "--without-dns" ] ; then
        echo 1
    else
        echo 0
    fi
}

extra_hosts_args() {
    DNS_EXTRA_HOSTS=
    DNS_EXTRA_HOSTS_ARGS=
    while [ $# -gt 0 ] ; do
        case "$1" in
            --add-host)
                DNS_EXTRA_HOSTS="$2 $DNS_EXTRA_HOSTS"
                DNS_EXTRA_HOSTS_ARGS="--add-host=$2 $DNS_EXTRA_HOSTS_ARGS"
                shift
                ;;
            --add-host=*)
                DNS_EXTRA_HOSTS="${1#*=} $DNS_EXTRA_HOSTS"
                DNS_EXTRA_HOSTS_ARGS="--add-host=${1#*=} $DNS_EXTRA_HOSTS_ARGS"
                ;;
        esac
        shift
    done
}

kill_container() {
    docker kill $1 >/dev/null 2>&1 || true
}

######################################################################
# main
######################################################################

check_docker_version

[ "$1" = "--local" ] && shift 1 && IS_LOCAL=1

# "--help|help" are special because we always want to process them
# at the client end.
handle_help_arg "$1" || handle_help_arg "--$1"

if [ "$1" = "version" -a -z "$IS_LOCAL" ] ; then
    # non-local "version" is special because we want to show the
    # version of the script executed by the user rather than what is
    # embedded in weaveexec.
    echo "weave script $SCRIPT_VERSION"
elif [ "$1" = "env" -a "$2" = "--restore" ] ; then
    # "env --restore" is special because we always want to process it
    # at the client end.
    if [ "${ORIG_DOCKER_HOST-unset}" = "unset" ] ; then
        echo "Nothing to restore. This is most likely because there was no preceding invocation of 'eval \$(weave env)' in this shell." >&2
        exit 1
    else
        echo "DOCKER_HOST=$ORIG_DOCKER_HOST"
        exit 0
    fi
elif [ "$1" = "run" -a -z "$IS_LOCAL" ] ; then
    # non-local "run" is a special case because we want to use docker
    # directly, rather than the docker in $EXEC_IMAGE remotely. That's
    # because we are passing arbitrary arguments on to docker run, and
    # we can't rely on our baked-in docker to support those arguments.
    shift 1

    handle_help_arg "$1"
    [ "$1" = "--without-dns" ] || DNS_ARGS=$(exec_remote dns-args "$@" || true)
    shift $(dns_arg_count "$@")

    REWRITE_HOSTS=1
    NO_MULTICAST_ROUTE=
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-rewrite-hosts)
                REWRITE_HOSTS=
                ;;
            --no-multicast-route)
                NO_MULTICAST_ROUTE=1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    [ -n "$REWRITE_HOSTS" ] && extra_hosts_args "$@" && DNS_EXTRA_HOSTS_ARGS="--rewrite-hosts $DNS_EXTRA_HOSTS_ARGS"
    [ -n "$NO_MULTICAST_ROUTE" ] && ATTACH_ARGS="--no-multicast-route"

    collect_cidr_args "$@"
    shift $CIDR_ARG_COUNT
    CONTAINER=$(docker $DOCKER_CLIENT_ARGS run -e WEAVE_CIDR=none $DNS_ARGS -d "$@")
    if ! exec_remote attach $CIDR_ARGS $DNS_EXTRA_HOSTS_ARGS $ATTACH_ARGS $CONTAINER >/dev/null ; then
        kill_container $CONTAINER
        exit 1
    fi
    echo $CONTAINER
    exit 0
fi

if [ -z "$IS_LOCAL" ] ; then
    exec_remote "$@"
    exit $?
fi

######################################################################
# main (remote and --local) - settings
######################################################################

# Default restart policy for router/proxy/plugin
RESTART_POLICY="--restart=always"
BASE_IMAGE=$DOCKERHUB_USER/weave
IMAGE=$BASE_IMAGE:$IMAGE_VERSION
CONTAINER_NAME=${WEAVE_CONTAINER_NAME:-weave}

BASE_PLUGIN_IMAGE=$DOCKERHUB_USER/plugin
PLUGIN_IMAGE=$BASE_PLUGIN_IMAGE:$IMAGE_VERSION
PLUGIN_CONTAINER_NAME=weaveplugin
CNI_PLUGIN_NAME="weave-plugin-$IMAGE_VERSION"
CNI_PLUGIN_DIR=${WEAVE_CNI_PLUGIN_DIR:-$HOST_ROOT/opt/cni/bin}
# Note VOLUMES_CONTAINER which is for weavewait should change when you upgrade Weave
VOLUMES_CONTAINER_NAME=weavevolumes-$IMAGE_VERSION
# DB files should remain when you upgrade, so version number not included in name
DB_CONTAINER_NAME=${CONTAINER_NAME}db

DOCKER_BRIDGE=${DOCKER_BRIDGE:-docker0}
BRIDGE=weave
# This value is overridden when the datapath is used unbridged
DATAPATH=datapath
CONTAINER_IFNAME=ethwe
BRIDGE_IFNAME=v${CONTAINER_IFNAME}-bridge
DATAPATH_IFNAME=v${CONTAINER_IFNAME}-datapath
PCAP_IFNAME=v${CONTAINER_IFNAME}-pcap
PORT=${WEAVE_PORT:-6783}
HTTP_ADDR=${WEAVE_HTTP_ADDR:-127.0.0.1:6784}
STATUS_ADDR=${WEAVE_STATUS_ADDR:-127.0.0.1:6782}
PROXY_PORT=12375
PROXY_CONTAINER_NAME=weaveproxy
COVERAGE_ARGS=""
[ -n "$COVERAGE" ] && COVERAGE_ARGS="-test.coverprofile=/home/weave/cover.prof --"

######################################################################
# general helpers; independent of docker and weave
######################################################################

# utility function to check whether a command can be executed by the shell
# see http://stackoverflow.com/questions/592620/how-to-check-if-a-program-exists-from-a-bash-script
command_exists() {
    command -v $1 >/dev/null 2>&1
}

fractional_sleep() {
    case $1 in
        *.*)
            if [ -z "$NO_FRACTIONAL_SLEEP" ] ; then
                sleep $1 >/dev/null 2>&1 && return 0
                NO_FRACTIONAL_SLEEP=1
            fi
            sleep $((${1%.*} + 1))
            ;;
        *)
            sleep $1
            ;;
    esac
}

run_iptables() {
    # -w is recent addition to iptables
    if [ -z "$CHECKED_IPTABLES_W" ] ; then
        iptables -S -w >/dev/null 2>&1 && IPTABLES_W=-w
        CHECKED_IPTABLES_W=1
    fi

    iptables $IPTABLES_W "$@"
}

# Add a rule to iptables, if it doesn't exist already
add_iptables_rule() {
    IPTABLES_TABLE="$1"
    shift 1
    if ! run_iptables -t $IPTABLES_TABLE -C "$@" >/dev/null 2>&1 ; then
        ## Loop until we get an exit code other than "temporarily unavailable"
        while true ; do
            run_iptables -t $IPTABLES_TABLE -A "$@" >/dev/null && return 0
            if [ $? != 4 ] ; then
                return 1
            fi
        done
    fi
}

# Insert a rule in iptables, if it doesn't exist already
insert_iptables_rule() {
    IPTABLES_TABLE="$1"
    shift 1
    if ! run_iptables -t $IPTABLES_TABLE -C "$@" >/dev/null 2>&1 ; then
        ## Loop until we get an exit code other than "temporarily unavailable"
        while true ; do
            run_iptables -t $IPTABLES_TABLE -I "$@" >/dev/null && return 0
            if [ $? != 4 ] ; then
                return 1
            fi
        done
    fi
}

# Delete a rule from iptables, if it exist
delete_iptables_rule() {
    IPTABLES_TABLE="$1"
    shift 1
    if run_iptables -t $IPTABLES_TABLE -C "$@" >/dev/null 2>&1 ; then
        run_iptables -t $IPTABLES_TABLE -D "$@" >/dev/null
    fi
}

# Configure the ARP cache parameters for the given interface.  This
# makes containers react more quickly to a change in the MAC address
# associated with an IP address.
configure_arp_cache() {
    $2 sh -c "echo 5 >/proc/sys/net/ipv4/neigh/$1/base_reachable_time &&
              echo 2 >/proc/sys/net/ipv4/neigh/$1/delay_first_probe_time &&
              echo 1 >/proc/sys/net/ipv4/neigh/$1/ucast_solicit"
}

# Send out an ARP announcement
# (https://tools.ietf.org/html/rfc5227#page-15) to update ARP cache
# entries across the weave network.  We do this in addition to
# configure_arp_cache because a) with those ARP cache settings it
# still takes a few seconds to correct a stale ARP mapping, and b)
# there is a kernel bug that means that the base_reachable_time
# setting is not promptly obeyed
# (<https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/commit/?id=4bf6980dd0328530783fd657c776e3719b421d30>>).
arp_update() {
    # It's not the end of the world if this doesn't run - we configure
    # ARP caches so that stale entries will be noticed quickly.
    ! command_exists arping || $3 arping -U -q -I $1 -c 1 ${2%/*}
}

# Generate a MAC value from a stdin containing six space separated
# 2-digit hexadecimal numbers.
mac_from_hex() {
    # In the first byte of the MAC, the 'multicast' bit should be
    # clear and 'locally administered' bit should be set.  All other
    # bits should be random.
    read a b c d e f && printf "%02x:$b:$c:$d:$e:$f" $((0x$a & ~1 | 2))
}

# Generate a random MAC value
random_mac() {
    od -txC -An -N6 /dev/urandom | mac_from_hex
}

######################################################################
# weave and docker specific helpers
######################################################################

check_docker_server_api_version() {
    # Cope with various versions of `docker version` output format
    if ! DOCKER_API_VERSION=$(docker version -f '{{.Server.APIVersion}}' 2> /dev/null ) ; then
        if ! DOCKER_API_VERSION=$(docker version -f '{{.Server.ApiVersion}}' 2> /dev/null ) ; then
            if ! DOCKER_API_VERSION=$(docker version | sed -n -e 's|^Server API version: *\([0-9][0-9]*\.[0-9][0-9]\).*|\1|p') || [ -z "$DOCKER_API_VERSION" ] ; then
                echo "ERROR: Unable to determine docker version" >&2
                exit 1
            fi
        fi
    fi

    if version_lt ${DOCKER_API_VERSION}.0 ${1}.0 ; then
        return 1
    fi
}

util_op() {
    if command_exists weaveutil ; then
        weaveutil "$@"
    else
        docker run --rm --privileged --net=host --pid=host $(docker_sock_options) \
            --entrypoint=/usr/bin/weaveutil $EXEC_IMAGE "$@"
    fi
}

check_forwarding_rules() {
    if run_iptables -C FORWARD -j REJECT --reject-with icmp-host-prohibited > /dev/null 2>&1; then
        cat >&2 <<EOF
WARNING: existing iptables rule

    '-A FORWARD -j REJECT --reject-with icmp-host-prohibited'

will block name resolution via weaveDNS - please reconfigure your firewall.
EOF
    fi
}

enforce_docker_bridge_addr_assign_type() {
    if ! ADDR_ASSIGN_TYPE=$(cat /sys/class/net/$DOCKER_BRIDGE/addr_assign_type 2>/dev/null) ; then
        echo "Could not determine address assignment type of $DOCKER_BRIDGE" >&2
        return
    fi
    # From include/uapi/linux/netdevice.h
    # #define NET_ADDR_PERM       0   /* address is permanent (default) */
    # #define NET_ADDR_RANDOM     1   /* address is generated randomly */
    # #define NET_ADDR_STOLEN     2   /* address is stolen from other device */
    # #define NET_ADDR_SET        3   /* address is set using dev_set_mac_address() */
    if [ $ADDR_ASSIGN_TYPE != 3 ] ; then
        echo "Setting $DOCKER_BRIDGE MAC (mitigate https://github.com/docker/docker/issues/14908)" >&2
        ip link set dev $DOCKER_BRIDGE address $(random_mac) || true
    fi
}

# Detect the current bridge/datapath state. When invoked, the values of
# $BRIDGE and $DATAPATH are expected to be distinct. $BRIDGE_TYPE and
# $DATAPATH are set correctly on success; failure indicates that the
# bridge/datapath devices have yet to be configured. If netdevs do exist
# but are in an inconsistent state the script aborts with an error.
detect_bridge_type() {
    BRIDGE_TYPE=
    if [ -d /sys/class/net/$DATAPATH ] ; then
        # Unfortunately there's no simple way to positively check whether
        # $DATAPATH is an ODP netdev so we have to make sure it isn't
        # a bridge instead (and that $BRIDGE is).
        if [ ! -d /sys/class/net/$DATAPATH/bridge -a -d /sys/class/net/$BRIDGE/bridge ] ; then
            BRIDGE_TYPE=bridged_fastdp
        else
            echo "Inconsistent bridge state detected. Please do 'weave reset' and try again." >&2
            exit 1
        fi
    elif [ -d /sys/class/net/$BRIDGE ] ; then
        if [ -d /sys/class/net/$BRIDGE/bridge ] ; then
            BRIDGE_TYPE=bridge
        else
            BRIDGE_TYPE=fastdp
            # The datapath is the bridge when there is no intermediary
            DATAPATH="$BRIDGE"
        fi
    else
        # No bridge/datapath devices configured
        return 1
    fi

    # WEAVE_MTU may have been specified when the bridge was
    # created (perhaps implicitly with WEAVE_NO_FASTDP).  So take
    # the MTU from the bridge unless it is explicitly specified
    # for this invocation.
    MTU=${WEAVE_MTU:-$(cat /sys/class/net/$BRIDGE/mtu)}
}

try_create_bridge() {
    if ! detect_bridge_type ; then
        BRIDGE_TYPE=bridge
        if [ -z "$WEAVE_NO_FASTDP" ] ; then
            BRIDGE_TYPE=bridged_fastdp
            if [ -n "$WEAVE_NO_BRIDGED_FASTDP" ] ; then
                BRIDGE_TYPE=fastdp
                # The datapath is the bridge when there is no intermediary
                DATAPATH="$BRIDGE"
            fi
            if util_op create-datapath $DATAPATH ; then
                : # ODP datapath created successfully
            elif [ $? = 17 ] ; then
                # Exit status of 17 means the kernel doesn't have ODP
                BRIDGE_TYPE=bridge
            else
                return 1
            fi
        fi

        init_$BRIDGE_TYPE

        # Drop traffic from Docker bridge to Weave; it can break
        # subnet isolation
        if [ "$DOCKER_BRIDGE" != "$BRIDGE" ] ; then
            # Note using -I to insert ahead of Docker's bridge rules
            run_iptables -t filter -I FORWARD -i $DOCKER_BRIDGE -o $BRIDGE -j DROP
        fi

        [ -n "$DOCKER_BRIDGE_IP" ] || DOCKER_BRIDGE_IP=$(util_op bridge-ip $DOCKER_BRIDGE)

        # forbid traffic to the Weave port from other containers
        add_iptables_rule filter INPUT -i $DOCKER_BRIDGE -p tcp --dst $DOCKER_BRIDGE_IP --dport $PORT          -j DROP
        add_iptables_rule filter INPUT -i $DOCKER_BRIDGE -p udp --dst $DOCKER_BRIDGE_IP --dport $PORT          -j DROP
        add_iptables_rule filter INPUT -i $DOCKER_BRIDGE -p udp --dst $DOCKER_BRIDGE_IP --dport $(($PORT + 1)) -j DROP

        # let DNS traffic to weaveDNS, since otherwise it might get blocked by the likes of UFW
        add_iptables_rule filter INPUT -i $DOCKER_BRIDGE -p udp --dport 53  -j ACCEPT
        add_iptables_rule filter INPUT -i $DOCKER_BRIDGE -p tcp --dport 53  -j ACCEPT

        if [ "$2" = "--expect-npc" ] ; then # matches usage in weave-kube launch.sh
            # Steer traffic via the NPC
            run_iptables -N WEAVE-NPC >/dev/null 2>&1 || true
            add_iptables_rule filter FORWARD -o $BRIDGE -j WEAVE-NPC
            add_iptables_rule filter FORWARD -o $BRIDGE -m state --state NEW -j NFLOG --nflog-group 86
            add_iptables_rule filter FORWARD -o $BRIDGE -j DROP
        else
            # Work around the situation where there are no rules allowing traffic
            # across our bridge. E.g. ufw
            add_iptables_rule filter FORWARD -i $BRIDGE -o $BRIDGE -j ACCEPT
        fi
        # Forward from weave to the rest of the world
        add_iptables_rule filter FORWARD -i $BRIDGE ! -o $BRIDGE -j ACCEPT
        # and allow replies back
        add_iptables_rule filter FORWARD -o $BRIDGE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

        # create a chain for masquerading
        run_iptables -t nat -N WEAVE >/dev/null 2>&1 || true
        add_iptables_rule nat POSTROUTING -j WEAVE
    else
        if [ -n "$LAUNCHING_ROUTER" ] ; then
            if [ "$BRIDGE_TYPE" = bridge -a -z "$WEAVE_NO_FASTDP" ] &&
                util_op check-datapath $DATAPATH 2>/dev/null ; then
                cat <<EOF >&2
WEAVE_NO_FASTDP is not set, but there is already a bridge present of
the wrong type for fast datapath.  Please do 'weave reset' to remove
the bridge first.
EOF
                return 1
            fi
            if [ "$BRIDGE_TYPE" != bridge -a -n "$WEAVE_NO_FASTDP" ] ; then
                cat <<EOF >&2
WEAVE_NO_FASTDP is set, but there is already a weave fast datapath
bridge present.  Please do 'weave reset' to remove the bridge first.
EOF
                return 1
            fi
        fi
    fi

    [ "$1" = "--without-ethtool" -o -n "$AWSVPC" ] || ethtool_tx_off_$BRIDGE_TYPE $BRIDGE

    ip link set dev $BRIDGE up

    # Configure the ARP cache parameters on the bridge interface for
    # the sake of 'weave expose'
    configure_arp_cache $BRIDGE
}

create_bridge() {
    if ! try_create_bridge "$@" ; then
        echo "Creating bridge '$BRIDGE' failed" >&2
        # reset to original value so we destroy both kinds
        DATAPATH=datapath
        destroy_bridge
        exit 1
    fi
}

expose_ip() {
    ipam_cidrs allocate_no_check_alive weave:expose $CIDR_ARGS
    for CIDR in $ALL_CIDRS ; do
        if ! ip addr show dev $BRIDGE | grep -qF $CIDR ; then
            ip addr add dev $BRIDGE $CIDR
            arp_update $BRIDGE $CIDR || true
            # Remove a default route installed by the kernel, because awsvpc
            # has installed it as well
            if [ -n "$AWSVPC" ]; then
                RCIDR=$(ip route list exact $CIDR proto kernel | head -n1 | cut -d' ' -f1)
                [ -n "$RCIDR" ] && ip route del dev $BRIDGE proto kernel $RCIDR
            fi
        fi
        [ -z "$FQDN" ] || when_weave_running put_dns_fqdn_no_check_alive weave:expose $FQDN $CIDR
    done
}

# create veth with ends $1-$2, and then invoke $3..., removing the
# veth on failure. No-op of veth already exists.
create_veth() {
    VETHL=$1
    VETHR=$2
    shift 2

    ip link show $VETHL >/dev/null 2>&1 && ip link show $VETHR >/dev/null 2>&1 && return 0

    ip link add name $VETHL mtu $MTU type veth peer name $VETHR mtu $MTU || return 1

    if ! ip link set $VETHL up || ! ip link set $VETHR up || ! "$@" ; then
        ip link del $VETHL >/dev/null 2>&1 || true
        ip link del $VETHR >/dev/null 2>&1 || true
        return 1
    fi
}

init_fastdp() {
    # GCE has the lowest underlay network MTU we're likely to encounter on
    # a local network, at 1460 bytes.  To get the overlay MTU from that we
    # subtract 20 bytes for the outer IPv4 header, 8 bytes for the outer
    # UDP header, 8 bytes for the vxlan header, and 14 bytes for the inner
    # ethernet header. In addition, we subtract 34 bytes for the ESP overhead
    # which is needed for the vxlan encryption.
    MTU=${WEAVE_MTU:-1376}

    # create_bridge already created the datapath netdev
    ip link set dev $DATAPATH mtu $MTU
}

init_bridge_prep() {
    # Observe any MTU that is already set
    [ -n "$MTU" ] || MTU=${WEAVE_MTU:-65535}

    ip link add name $BRIDGE type bridge

    # Running this from 'weave --local' when weaveexec is not on the
    # path will run it as a Docker container that does not have access
    # to /etc/machine-id, so will not give the full range of persistent IDs
    WEAVEDB_PATH=$(docker inspect -f '{{with index .Mounts 0}}{{.Source}}{{end}}' $DB_CONTAINER_NAME 2>/dev/null)
    MAC=$(util_op unique-id "$HOST_ROOT/$WEAVEDB_PATH/weave" "$HOST_ROOT")

    ip link set dev $BRIDGE address $MAC

    # Attempting to set the bridge MTU to a high value directly
    # fails. Bridges take the lowest MTU of their interfaces. So
    # instead we create a temporary interface with the desired
    # MTU, attach that to the bridge, and then remove it again.
    ip link add name v${CONTAINER_IFNAME}du mtu $MTU type dummy
    ip link set dev v${CONTAINER_IFNAME}du master $BRIDGE
    ip link del dev v${CONTAINER_IFNAME}du
}

init_bridge() {
    init_bridge_prep
    create_veth $BRIDGE_IFNAME $PCAP_IFNAME add_iface_bridge $BRIDGE_IFNAME
}

init_bridged_fastdp() {
    # Initialise the datapath as normal. NB sets MTU for use below
    init_fastdp

    # Initialise the bridge using fast datapath MTU
    init_bridge_prep

    # Create linking veth pair
    create_veth $BRIDGE_IFNAME $DATAPATH_IFNAME configure_veth_bridged_fastdp

    # Finally, bring the datapath up
    ip link set dev $DATAPATH up
}

configure_veth_bridged_fastdp() {
    add_iface_fastdp $DATAPATH_IFNAME || return 1
    add_iface_bridge $BRIDGE_IFNAME || return 1
}

ethtool_tx_off_fastdp() {
    true
}

ethtool_tx_off_bridge() {
    ethtool -K $1 tx off >/dev/null
}

ethtool_tx_off_bridged_fastdp() {
    true
}

destroy_bridge() {
    # It's important that detect_bridge_type has not been called so
    # we have distinct values for $BRIDGE and $DATAPATH. Make best efforts
    # to remove netdevs of any type with those names so `weave reset` can
    # recover from inconsistent states.
    for NETDEV in $BRIDGE $DATAPATH ; do
        if [ -d /sys/class/net/$NETDEV ] ; then
            if [ -d /sys/class/net/$NETDEV/bridge ] ; then
                ip link del $NETDEV
            else
                util_op delete-datapath $NETDEV
            fi
        fi
    done

    # Remove any lingering bridged fastdp, pcap and attach-bridge veths
    for VETH in $(ip -o link show | grep -o v${CONTAINER_IFNAME}[^:@]*) ; do
        ip link del $VETH >/dev/null 2>&1 || true
    done

    if [ "$DOCKER_BRIDGE" != "$BRIDGE" ] ; then
        run_iptables -t filter -D FORWARD -i $DOCKER_BRIDGE -o $BRIDGE -j DROP 2>/dev/null || true
    fi

    [ -n "$DOCKER_BRIDGE_IP" ] || DOCKER_BRIDGE_IP=$(util_op bridge-ip $DOCKER_BRIDGE)

    run_iptables -t filter -D INPUT -i $DOCKER_BRIDGE -p udp --dport 53  -j ACCEPT  >/dev/null 2>&1 || true
    run_iptables -t filter -D INPUT -i $DOCKER_BRIDGE -p tcp --dport 53  -j ACCEPT  >/dev/null 2>&1 || true

    run_iptables -t filter -D INPUT -i $DOCKER_BRIDGE -p tcp --dst $DOCKER_BRIDGE_IP --dport $PORT          -j DROP >/dev/null 2>&1 || true
    run_iptables -t filter -D INPUT -i $DOCKER_BRIDGE -p udp --dst $DOCKER_BRIDGE_IP --dport $PORT          -j DROP >/dev/null 2>&1 || true
    run_iptables -t filter -D INPUT -i $DOCKER_BRIDGE -p udp --dst $DOCKER_BRIDGE_IP --dport $(($PORT + 1)) -j DROP >/dev/null 2>&1 || true

    run_iptables -t filter -D FORWARD -i $BRIDGE ! -o $BRIDGE -j ACCEPT 2>/dev/null || true
    run_iptables -t filter -D FORWARD -o $BRIDGE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    run_iptables -t filter -D FORWARD -i $BRIDGE -o $BRIDGE -j ACCEPT 2>/dev/null || true
    run_iptables -F WEAVE-NPC >/dev/null 2>&1 || true
    run_iptables -t filter -D FORWARD -o $BRIDGE -j WEAVE-NPC 2>/dev/null || true
    run_iptables -t filter -D FORWARD -o $BRIDGE -m state --state NEW -j NFLOG --nflog-group 86 2>/dev/null || true
    run_iptables -t filter -D FORWARD -o $BRIDGE -j DROP 2>/dev/null || true
    run_iptables -X WEAVE-NPC >/dev/null 2>&1 || true
    run_iptables -t nat -F WEAVE >/dev/null 2>&1 || true
    run_iptables -t nat -D POSTROUTING -j WEAVE >/dev/null 2>&1 || true
    run_iptables -t nat -D POSTROUTING -o $BRIDGE -j ACCEPT >/dev/null 2>&1 || true
    run_iptables -t nat -X WEAVE >/dev/null 2>&1 || true
}

do_or_die() {
    CONTAINER="$1"
    shift 1
    if ! "$@" ; then
        kill_container $CONTAINER
        exit 1
    fi
}

add_iface_fastdp() {
    util_op add-datapath-interface $DATAPATH $1
}

add_iface_bridge() {
    ip link set $1 master $BRIDGE
}

add_iface_bridged_fastdp() {
    add_iface_bridge "$@"
}

attach_bridge() {
    bridge="$1"
    LOCAL_IFNAME=v${CONTAINER_IFNAME}bl$bridge
    GUEST_IFNAME=v${CONTAINER_IFNAME}bg$bridge

    create_veth $LOCAL_IFNAME $GUEST_IFNAME configure_veth_attached_bridge
}

configure_veth_attached_bridge() {
    add_iface_$BRIDGE_TYPE $LOCAL_IFNAME || return 1
    ip link set $GUEST_IFNAME master $bridge
}

router_opts_fastdp() {
    echo "--datapath $DATAPATH"
}

router_opts_bridge() {
    echo "--iface $PCAP_IFNAME"
}

router_opts_bridged_fastdp() {
    router_opts_fastdp "$@"
}

ask_version() {
    if check_running $1 2>/dev/null ; then
        DOCKERIMAGE=$(docker inspect --format='{{.Image}}' $1 )
    elif ! DOCKERIMAGE=$(docker inspect --format='{{.Id}}' $2 2>/dev/null) ; then
        echo "Unable to find $2 image." >&2
    fi
    [ -n "$DOCKERIMAGE" ] && docker run --rm --net=none -e WEAVE_CIDR=none $3 $DOCKERIMAGE $COVERAGE_ARGS --version
}

attach() {
    ATTACH_ARGS=""
    [ -n "$NO_MULTICAST_ROUTE" ] && ATTACH_ARGS="--no-multicast-route"
    # Relying on AWSVPC being set in 'ipam_cidrs allocate', except for 'weave restart'
    [ -n "$AWSVPC" ] && ATTACH_ARGS="--no-multicast-route --keep-tx-on"
    util_op attach-container $ATTACH_ARGS $CONTAINER $BRIDGE $MTU "$@"
}

######################################################################
# functions for interacting with containers
######################################################################

# Check that a container for component $1 named $2 with image $3 is not running
check_not_running() {
    RUN_STATUS=$(docker inspect --format='{{.State.Running}} {{.State.Status}} {{.Config.Image}}' $2 2>/dev/null) || true
    case ${RUN_STATUS%:*} in
        "true restarting $3")
            echo "$2 is restarting; you can stop it with 'weave stop-$1'." >&2
            return 3
            ;;
        "true "*" $3")
            echo "$2 is already running; you can stop it with 'weave stop-$1'." >&2
            return 1
            ;;
        "false "*" $3")
            docker rm $2 >/dev/null
            ;;
        true*)
            echo "Found another running container named '$2'. Aborting." >&2
            return 2
            ;;
        false*)
            echo "Found another container named '$2'. Aborting." >&2
            return 2
            ;;
    esac
}

stop() {
    docker stop $1 >/dev/null 2>&1 || echo "$2 is not running." >&2
}

# Given a container name or short ID in $1, ensure the specified
# container exists and then print its full ID to stdout. If
# it doesn't exist, print an error to stderr and
# return with an indicative non-zero exit code.
container_id() {
    if ! docker inspect --format='{{.Id}}' $1 2>/dev/null ; then
        echo "Error: No such container: $1" >&2
        return 1
    fi
}

http_call() {
    addr="$1"
    http_verb="$2"
    url="$3"
    shift 3
    CURL_TMPOUT=/tmp/weave_curl_out_$$
    HTTP_CODE=$(curl -o $CURL_TMPOUT -w '%{http_code}' --connect-timeout 3 -s -S -X $http_verb "$@" http://$addr$url) || return $?
    case "$HTTP_CODE" in
        2??) # 2xx -> not an error; output response on stdout
            [ -f $CURL_TMPOUT ] && cat $CURL_TMPOUT
            retval=0
            ;;
        404) # treat as error but swallow response
            retval=4
            ;;
        *) # anything else is an error; output response on stderr
            [ -f $CURL_TMPOUT ] && cat $CURL_TMPOUT >&2
            retval=1
    esac
    rm -f $CURL_TMPOUT
    return $retval
}

http_call_unix() {
    container="$1"
    socket="$2"
    http_verb="$3"
    url="$4"
    shift 4
    # NB: requires curl >= 7.40
    output=$(docker exec $container curl -s -S -X $http_verb --unix-socket $socket "$@" http:$url) || return 1
    # in some docker versions, `docker exec` does not fail when the executed command fails
    [ -n "$output" ] || return 1
    echo $output
}

call_weave() {
    TMPERR=/tmp/call_weave_err_$$
    retval=0
    http_call $HTTP_ADDR "$@" 2>$TMPERR || retval=$?
    if [ $retval -ne 0 ] ; then
        check_running $CONTAINER_NAME && cat $TMPERR >&2
    fi
    rm -f $TMPERR
    return $retval
}

death_msg() {
    echo "The $1 container has died. Consult the container logs for further details."
}

# Wait until container $1 is alive enough to respond to "GET /status"
# http request
wait_for_status() {
    container="$1"
    shift
    while true ; do
        "$@" GET /status >/dev/null 2>&1 && return 0
        if ! check_running $container >/dev/null 2>&1 ; then
            kill_container $container # stop it restarting
            echo $(death_msg $container) >&2
            return 1
        fi
        fractional_sleep 0.1
    done
}

# Call $1 for all containers, passing container ID, all MACs and all IPs
with_container_addresses() {
    COMMAND=$1
    shift 1

    CONTAINER_ADDRS=$(util_op container-addrs $BRIDGE "$@") || return 1
    echo "$CONTAINER_ADDRS" |  while read CONTAINER_ID CONTAINER_IFACE CONTAINER_MAC CONTAINER_IPS; do
        $COMMAND "$CONTAINER_ID" "$CONTAINER_IFACE" "$CONTAINER_MAC" "$CONTAINER_IPS"
    done
}

echo_addresses() {
    echo $1 $3 $4
}

echo_ips() {
    for CIDR in $4; do
        echo ${CIDR%/*}
    done
}

echo_cidrs() {
    echo $4
}

peer_args() {
    res=''
    sep=''
    for p in "$@" ; do
        res="$res${sep}peer=$p"
        sep="&"
    done
    echo "$res"
}

######################################################################
# CNI helpers
######################################################################

install_cni_plugin() {
    mkdir -p $1 || return 1
    if [ ! -f "$1/$CNI_PLUGIN_NAME" ]; then
        cp /usr/bin/weaveutil "$1/$CNI_PLUGIN_NAME"
    fi
}

upgrade_cni_plugin_symlink() {
    # Remove potential temporary symlink from previous failed upgrade:
    rm -f $1/$2.tmp
    # Atomically create a symlink to the plugin:
    ln -s "$CNI_PLUGIN_NAME" $1/$2.tmp && mv -f $1/$2.tmp $1/$2
}

upgrade_cni_plugin() {
    # Check if weave-net and weave-ipam are (legacy) copies of the plugin, and
    # if so remove these so symlinks can be used instead from now onwards.
    if [ -f $1/weave-net  -a ! -L $1/weave-net  ];  then rm $1/weave-net;   fi
    if [ -f $1/weave-ipam -a ! -L $1/weave-ipam ];  then rm $1/weave-ipam;  fi

    # Create two symlinks to the plugin, as it has different
    # behaviour depending on its name:
    if [ "$(readlink -f $1/weave-net)" != "$CNI_PLUGIN_NAME" ]; then
        upgrade_cni_plugin_symlink $1 weave-net
    fi
    if [ "$(readlink -f $1/weave-ipam)" != "$CNI_PLUGIN_NAME" ]; then
        upgrade_cni_plugin_symlink $1 weave-ipam
    fi
}

create_cni_config() {
    cat >"$1" <<EOF
{
    "name": "weave",
    "type": "weave-net",
    "hairpinMode": $2
}
EOF
}

setup_cni() {
    # if env var HAIRPIN_MODE is not set, default it to true
    HAIRPIN_MODE=${HAIRPIN_MODE:-true}
    if install_cni_plugin $CNI_PLUGIN_DIR ; then
        upgrade_cni_plugin $CNI_PLUGIN_DIR
    fi
    if [ -d $HOST_ROOT/etc/cni/net.d -a ! -f $HOST_ROOT/etc/cni/net.d/10-weave.conf ] ; then
        create_cni_config $HOST_ROOT/etc/cni/net.d/10-weave.conf $HAIRPIN_MODE
    fi
}

######################################################################
# weaveDNS helpers
######################################################################

dns_args() {
    retval=0
    # NB: this is memoized
    DNS_DOMAIN=${DNS_DOMAIN:-$(call_weave GET /domain 2>/dev/null)} || retval=$?
    [ "$retval" -eq 4 ] && return 0
    DNS_DOMAIN=${DNS_DOMAIN:-weave.local.}

    NAME_ARG=""
    HOSTNAME_SPECIFIED=
    DNS_SEARCH_SPECIFIED=
    WITHOUT_DNS=
    while [ $# -gt 0 ] ; do
        case "$1" in
            --with-dns)
                echo "Warning: $1 is deprecated; it is on by default" >&2
                ;;
            --without-dns)
                WITHOUT_DNS=1
                ;;
            --name)
                NAME_ARG="$2"
                shift
                ;;
            --name=*)
                NAME_ARG="${1#*=}"
                ;;
            -h|--hostname|--hostname=*)
                HOSTNAME_SPECIFIED=1
                ;;
            --dns-search|--dns-search=*)
                DNS_SEARCH_SPECIFIED=1
                ;;
        esac
        shift
    done
    [ -n "$WITHOUT_DNS" ] && return 0

    [ -n "$DOCKER_BRIDGE_IP" ] || DOCKER_BRIDGE_IP=$(util_op bridge-ip $DOCKER_BRIDGE)
    DNS_ARGS="--dns=$DOCKER_BRIDGE_IP"
    if [ -n "$NAME_ARG" -a -z "$HOSTNAME_SPECIFIED" ] ; then
        HOSTNAME="$NAME_ARG.${DNS_DOMAIN%.}"
        if [ ${#HOSTNAME} -gt 64 ] ; then
            echo "Container name too long to be used as hostname" >&2
        else
            DNS_ARGS="$DNS_ARGS --hostname=$HOSTNAME"
            HOSTNAME_SPECIFIED=1
        fi
    fi
    if [ -z "$DNS_SEARCH_SPECIFIED" ] ; then
      if [ -z "$HOSTNAME_SPECIFIED" ] ; then
        DNS_ARGS="$DNS_ARGS --dns-search=$DNS_DOMAIN"
      else
        DNS_ARGS="$DNS_ARGS --dns-search=."
      fi
    fi
}

etc_hosts_contents() {
    FQDN=$1
    shift
    NAME=${FQDN%%.*}
    HOSTNAMES="$NAME"
    [ "$NAME" = "$FQDN" -o "$NAME." = "$FQDN" ] || HOSTNAMES="${FQDN%.} $HOSTNAMES"

    echo "# created by Weave - BEGIN"
    echo "# container hostname"
    for CIDR in $ALL_CIDRS ; do
        echo "${CIDR%/*}    $HOSTNAMES"
    done
    echo
    echo "# static names added with --add-host"
    for EXTRA_HOST in "$@" ; do
        echo "${EXTRA_HOST#*:}     ${EXTRA_HOST%:*}"
    done

    cat <<-EOF

# default localhost entries
127.0.0.1       localhost
::1             ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

    echo "# created by Weave - END"
}

rewrite_etc_hosts() {
    HOSTS_PATH_AND_FQDN=$(docker inspect -f '{{.HostsPath}} {{.Config.Hostname}}.{{.Config.Domainname}}' $CONTAINER) || return 1
    HOSTS=${HOSTS_PATH_AND_FQDN% *}
    FQDN=${HOSTS_PATH_AND_FQDN#* }
    CONTAINERS_PATH=$(dirname $HOSTS)
    MNT=/container
    MNT_HOSTS=$MNT/$(basename $HOSTS)
    CONTENTS="$(etc_hosts_contents $FQDN "$@")"
    # rewrite /etc/hosts, unlinking the file (so Docker does not modify it again) but
    # leaving it with valid contents...
    docker run --rm --net=none -e WEAVE_CIDR=none --privileged \
        -v $CONTAINERS_PATH:$MNT \
        --entrypoint=sh \
        $EXEC_IMAGE -c "echo '$CONTENTS' > $MNT_HOSTS && rm -f $MNT_HOSTS && echo '$CONTENTS' > $MNT_HOSTS"
}

# Print an error to stderr and return with an indicative exit status
# if the container $1 does not exist or isn't running.
check_running() {
    if ! STATUS=$(docker inspect --format='{{.State.Running}} {{.State.Restarting}}' $1 2>/dev/null) ; then
        echo  "$1 container is not present. Have you launched it?" >&2
        return 1
    elif [ "$STATUS" = "true true" ] ; then
        echo "$1 container is restarting." >&2
        return 2
    elif [ "$STATUS" != "true false" ] ; then
        echo "$1 container is not running." >&2
        return 2
    fi
}

# Execute $@ only if the weave container is running
when_weave_running() {
    ! check_running $CONTAINER_NAME 2>/dev/null || "$@"
}

# Iff the container in $1 has an FQDN, invoke $2 as a command passing
# the container as the first argument, the FQDN as the second argument
# and $3.. as additional arguments
with_container_fqdn() {
    CONT="$1"
    COMMAND="$2"
    shift 2

    CONT_FQDN=$(docker inspect --format='{{.Config.Hostname}}.{{.Config.Domainname}}' $CONT 2>/dev/null) || return 0
    CONT_NAME=${CONT_FQDN%%.*}
    [ "$CONT_NAME" = "$CONT_FQDN" -o "$CONT_NAME." = "$CONT_FQDN" ] || $COMMAND "$CONT" "$CONT_FQDN" "$@"
}

# Register FQDN in $2 as names for addresses $3.. under full container ID $1
put_dns_fqdn() {
    CHECK_ALIVE="-d check-alive=true"
    put_dns_fqdn_helper "$@"
}

put_dns_fqdn_no_check_alive() {
    CHECK_ALIVE=
    put_dns_fqdn_helper "$@"
}

put_dns_fqdn_helper() {
    CONTAINER_ID="$1"
    FQDN="$2"
    shift 2

    for ADDR in "$@" ; do
        call_weave PUT /name/$CONTAINER_ID/${ADDR%/*} --data-urlencode fqdn=$FQDN $CHECK_ALIVE || true
    done
}

# Delete all names for addresses $3.. under full container ID $1
delete_dns() {
    CONTAINER_ID="$1"
    shift 1

    for ADDR in "$@" ; do
        call_weave DELETE /name/$CONTAINER_ID/${ADDR%/*} || true
    done
}

# Delete any FQDNs $2 from addresses $3.. under full container ID $1
delete_dns_fqdn() {
    CONTAINER_ID="$1"
    FQDN="$2"
    shift 2

    for ADDR in "$@" ; do
        call_weave DELETE /name/$CONTAINER_ID/${ADDR%/*}?fqdn=$FQDN || true
    done
}

is_ip() {
    echo "$1" | grep -E "^$IP_REGEXP$" >/dev/null
}

collect_ip_args() {
    IP_ARGS=""
    IP_COUNT=0
    while is_ip "$1" ; do
        IP_ARGS="$IP_ARGS $1"
        IP_COUNT=$((IP_COUNT + 1))
        shift 1
    done
}

collect_dns_add_remove_args() {
    collect_ip_args "$@"
    shift $IP_COUNT
    [ $# -gt 0 -a "$1" != "-h" ] &&    C="$1" && shift 1
    [ $# -eq 2 -a "$1"  = "-h" ] && FQDN="$2" && shift 2
    [ $# -eq 0 -a \( -n "$C" -o \( $IP_COUNT -gt 0 -a -n "$FQDN" \) \) ] || usage
    check_running $CONTAINER_NAME
    if [ -n "$C" ] ; then
        check_running $C
        CONTAINER=$(container_id $C)
        [ $IP_COUNT -gt 0 ] || IP_ARGS=$(with_container_addresses echo_ips $CONTAINER)
    fi
}

######################################################################
# IP Allocation Management helpers
######################################################################

check_overlap() {
    util_op netcheck $1 $BRIDGE
}

detect_awsvpc() {
    # Ignoring errors here: if we cannot detect AWSVPC we will skip the relevant
    # steps, because "attach" should work without the weave router running.
    [ "$(call_weave GET /ipinfo/tracker)" != "awsvpc" ] || AWSVPC=1
}

# Call IPAM as necessary to lookup or allocate addresses
#
# $1 is one of 'lookup', 'allocate' or 'allocate_no_check_alive', $2
# is the full container id. The remaining args are previously parsed
# CIDR_ARGS.
#
# Populates ALL_CIDRS and IPAM_CIDRS
ipam_cidrs() {
    case $1 in
        lookup)
            METHOD=GET
            CHECK_ALIVE=
            ;;
        allocate)
            METHOD=POST
            CHECK_ALIVE="?check-alive=true"
            detect_awsvpc
            if [ -n "$AWSVPC" -a $# -gt 2 ] ; then
                echo "Error: no IP addresses or subnets may be specified in AWSVPC mode" >&2
                return 1
            fi
            ;;
        allocate_no_check_alive)
            METHOD=POST
            CHECK_ALIVE=
            ;;
    esac
    CONTAINER_ID="$2"
    shift 2
    ALL_CIDRS=""
    IPAM_CIDRS=""
    # If no addresses passed in, select the default subnet
    [ $# -gt 0 ] || set -- net:default
    for arg in "$@" ; do
        if [ "${arg%:*}" = "net" ] ; then
            if [ "$arg" = "net:default" ] ; then
                IPAM_URL=/ip/$CONTAINER_ID
            else
                IPAM_URL=/ip/$CONTAINER_ID/"${arg#net:}"
            fi
            retval=0
            CIDR=$(call_weave $METHOD $IPAM_URL$CHECK_ALIVE) || retval=$?
            if [ $retval -eq 4 -a "$METHOD" = "POST" ] ; then
                echo "IP address allocation must be enabled to use 'net:'" >&2
                return 1
            fi
            [ $retval -gt 0 ] && return $retval
            IPAM_CIDRS="$IPAM_CIDRS $CIDR"
            ALL_CIDRS="$ALL_CIDRS $CIDR"
        else
            if [ "$METHOD" = "POST" ] ; then
                # Assignment of a plain IP address; warn if it clashes but carry on
                check_overlap $arg || true
                # Abort on failure, but not 4 (=404), which means IPAM is disabled
                when_weave_running http_call $HTTP_ADDR PUT /ip/$CONTAINER_ID/$arg$CHECK_ALIVE || [ $? -eq 4 ] || return 1
            fi
            ALL_CIDRS="$ALL_CIDRS $arg"
        fi
    done
}

ipam_cidrs_or_die() {
    if ! ipam_cidrs "$@" ; then
        kill_container $2
        exit 1
    fi
}

show_addrs() {
    addrs=
    for cidr in "$@" ; do
        addrs="$addrs ${cidr%/*}"
    done
    echo $addrs
}

######################################################################
# weave proxy helpers
######################################################################

docker_client_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
          -H|--host)
            DOCKER_CLIENT_HOST="$2"
            shift
            ;;
          -H=*|--host=*)
            DOCKER_CLIENT_HOST="${1#*=}"
            ;;
        esac
        shift
    done
}

# TODO: Handle relative paths for args
# TODO: Handle args with spaces
tls_arg() {
    PROXY_VOLUMES="$PROXY_VOLUMES -v $2:/home/weave/tls/$3.pem:ro"
    PROXY_ARGS="$PROXY_ARGS $1 /home/weave/tls/$3.pem"
}

# TODO: Handle relative paths for args
# TODO: Handle args with spaces
host_arg() {
  PROXY_HOST="$1"
  if [ "$PROXY_HOST" != "${PROXY_HOST#unix://}" ]; then
    host=$(dirname ${PROXY_HOST#unix://})
    if [ "$host" = "${host#/}" ]; then
      echo "When launching the proxy, unix sockets must be specified as an absolute path." >&2
      exit 1
    fi
    PROXY_VOLUMES="$PROXY_VOLUMES -v /var/run/weave:/var/run/weave"
  fi
  PROXY_ARGS="$PROXY_ARGS -H $1"
}

proxy_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
          -H)
            host_arg "$2"
            shift
            ;;
          -H=*)
            host_arg "${1#*=}"
            ;;
          -no-detect-tls|--no-detect-tls)
            PROXY_TLS_DETECTION_DISABLED=1
            ;;
          -tls|--tls|-tlsverify|--tlsverify)
            PROXY_TLS_ENABLED=1
            PROXY_ARGS="$PROXY_ARGS $1"
            ;;
          --tlscacert)
            tls_arg "$1" "$2" ca
            shift
            ;;
          --tlscacert=*)
            tls_arg "${1%%=*}" "${1#*=}" ca
            ;;
          --tlscert)
            tls_arg "$1" "$2" cert
            shift
            ;;
          --tlscert=*)
            tls_arg "${1%%=*}" "${1#*=}" cert
            ;;
          --tlskey)
            tls_arg "$1" "$2" key
            shift
            ;;
          --tlskey=*)
            tls_arg "${1%%=*}" "${1#*=}" key
            ;;
          --no-restart)
            RESTART_POLICY=
            ;;
          *)
            PROXY_ARGS="$PROXY_ARGS $1"
            ;;
        esac
        shift
    done
}

proxy_args() {
    PROXY_VOLUMES=""
    PROXY_ARGS=""
    PROXY_TLS_ENABLED=""
    PROXY_TLS_DETECTION_DISABLED=""
    PROXY_HOST=""
    proxy_parse_args "$@"

    if [ -z "$PROXY_TLS_ENABLED" -a -z "$PROXY_TLS_DETECTION_DISABLED" ] ; then
        if ! DOCKER_TLS_ARGS=$(util_op docker-tls-args) ; then
            echo -n "Warning: unable to detect proxy TLS configuration. To enable TLS, " >&2
            echo -n "launch the proxy with 'weave launch-proxy' and supply TLS options. " >&2
            echo "To suppress this warning, supply the '--no-detect-tls' option." >&2
        else
            proxy_parse_args $DOCKER_TLS_ARGS
        fi
    fi
    if [ -z "$PROXY_HOST" ] ; then
      case "$DOCKER_CLIENT_HOST" in
        ""|unix://*)
          PROXY_HOST="unix:///var/run/weave/weave.sock"
          ;;
        *)
          PROXY_HOST="tcp://0.0.0.0:$PROXY_PORT"
          ;;
      esac
      host_arg "$PROXY_HOST"
    fi
}

proxy_addrs() {
    if addr="$(http_call_unix $PROXY_CONTAINER_NAME status.sock GET /status 2>/dev/null)" ; then
      echo "$addr" | sed "s/0.0.0.0/$PROXY_HOST/g"

    else
      echo "$PROXY_CONTAINER_NAME container is not present. Have you launched it?" >&2
      return 1
    fi
}

proxy_addr() {
    addr=$(proxy_addrs) || return 1
    echo "$addr" | cut -d ' ' -f1
}

warn_if_stopping_proxy_in_env() {
    if PROXY_ADDR=$(proxy_addr 2>/dev/null) ; then
        [ "$PROXY_ADDR" != "$DOCKER_CLIENT_HOST" ] || echo "WARNING: It appears that your environment is configured to use the Weave Docker API proxy. Stopping it will break this and subsequent docker invocations. To restore your environment, run 'eval \$(weave env --restore)'."
    fi
}

######################################################################
# launch helpers
######################################################################

common_launch_args() {
    args=""
    while [ $# -gt 0 ] ; do
        case "$1" in
            --no-restart)
                args="$args $1"
                ;;
            --log-level)
                [ $# -gt 1 ] || usage
                args="$args $1 $2"
                shift
                ;;
            --log-level=*)
                args="$args $1"
                ;;
        esac
        shift
    done
    echo "$args"
}

launch_router() {
    LAUNCHING_ROUTER=1
    check_forwarding_rules
    enforce_docker_bridge_addr_assign_type

    # backward compatibility...
    if is_cidr "$1" ; then
        echo "WARNING: $1 parameter ignored; 'weave launch' no longer takes a CIDR as the first parameter" >&2
        shift 1
    fi

    CONTAINER_PORT=$PORT
    ARGS=
    IPRANGE=
    IPRANGE_SPECIFIED=

    [ -n "$DOCKER_BRIDGE_IP" ] || DOCKER_BRIDGE_IP=$(util_op bridge-ip $DOCKER_BRIDGE)
    DNS_ROUTER_OPTS="--dns-listen-address $DOCKER_BRIDGE_IP:53"
    NO_DNS_OPT=

    while [ $# -gt 0 ] ; do
        case "$1" in
            -password|--password)
                [ $# -gt 1 ] || usage
                WEAVE_PASSWORD="$2"
                export WEAVE_PASSWORD
                shift
                ;;
            --password=*)
                WEAVE_PASSWORD="${1#*=}"
                export WEAVE_PASSWORD
                ;;
            -port|--port)
                [ $# -gt 1 ] || usage
                CONTAINER_PORT="$2"
                shift
                ;;
            --port=*)
                CONTAINER_PORT="${1#*=}"
                ;;
            -iprange|--iprange|--ipalloc-range)
                [ $# -gt 1 ] || usage
                IPRANGE="$2"
                IPRANGE_SPECIFIED=1
                shift
                ;;
            --ipalloc-range=*)
                IPRANGE="${1#*=}"
                IPRANGE_SPECIFIED=1
                ;;
            --no-dns)
                DNS_ROUTER_OPTS=
                NO_DNS_OPT="--no-dns"
                ;;
            --no-restart)
                RESTART_POLICY=
                ;;
            --awsvpc)
                AWSVPC_ARGS="--awsvpc"
                AWSVPC=1
                ;;
            *)
                ARGS="$ARGS '$(echo "$1" | sed "s|'|'\"'\"'|g")'"
                ;;
        esac
        shift
    done
    eval "set -- $ARGS"

    setup_cni
    create_bridge
    # We set the router name to the bridge MAC, which in turn is
    # derived from the system UUID (if available), and thus stable
    # across reboots.
    PEERNAME=$(cat /sys/class/net/$BRIDGE/address)

    if [ -z "$IPRANGE_SPECIFIED" ] ; then
        IPRANGE="10.32.0.0/12"
        if ! check_overlap $IPRANGE ; then
            echo "ERROR: Default --ipalloc-range $IPRANGE overlaps with existing route on host." >&2
            echo "You must pick another range and set it on all hosts." >&2
            exit 1
        fi
    else
        if [ -n "$AWSVPC" -a -z "$IPRANGE" ] ; then
            echo "ERROR: Empty --ipalloc-range is not compatible with --awsvpc." >&2
            exit 1
        fi
        if [ -n "$IPRANGE" ] && ! check_overlap $IPRANGE ; then
            echo "WARNING: Specified --ipalloc-range $IPRANGE overlaps with existing route on host." >&2
            echo "Unless this is deliberate, you must pick another range and set it on all hosts." >&2
        fi
    fi

    # Create a data-only container for persistence data
    if ! docker inspect -f ' ' $DB_CONTAINER_NAME > /dev/null 2>&1 ; then
       protect_against_docker_hang
       docker create -v /weavedb --name=$DB_CONTAINER_NAME \
           --label=weavevolumes $WEAVEDB_IMAGE >/dev/null
    fi

    # Figure out the location of the actual resolv.conf file because
    # we want to bind mount its directory into the container.
    if [ -L ${HOST_ROOT:-/}/etc/resolv.conf ]; then # symlink
        # This assumes a host with readlink in FHS directories...
        # Ideally, this would resolve the symlink manually, without
        # using host commands.
        RESOLV_CONF=$(chroot ${HOST_ROOT:-/} readlink -f /etc/resolv.conf)
    else
        RESOLV_CONF=/etc/resolv.conf
    fi
    RESOLV_CONF_DIR=$(dirname "$RESOLV_CONF")
    RESOLV_CONF_BASE=$(basename "$RESOLV_CONF")

    # Set WEAVE_DOCKER_ARGS in the environment in order to supply
    # additional parameters, such as resource limits, to docker
    # when launching the weave container.
    ROUTER_CONTAINER=$(docker run -d --name=$CONTAINER_NAME \
        $(docker_run_options) \
        $RESTART_POLICY \
        --pid=host \
        --volumes-from $DB_CONTAINER_NAME \
        -v $RESOLV_CONF_DIR:/var/run/weave/etc \
        -e WEAVE_PASSWORD \
        -e CHECKPOINT_DISABLE \
        $WEAVE_DOCKER_ARGS $IMAGE $COVERAGE_ARGS \
        --port $CONTAINER_PORT --name "$PEERNAME" --nickname "$(hostname)" \
        $(router_opts_$BRIDGE_TYPE) \
        --ipalloc-range "$IPRANGE" \
        --dns-effective-listen-address $DOCKER_BRIDGE_IP \
        $DNS_ROUTER_OPTS $NO_DNS_OPT \
        $AWSVPC_ARGS \
        --http-addr $HTTP_ADDR \
        --status-addr $STATUS_ADDR \
        --resolv-conf "/var/run/weave/etc/$RESOLV_CONF_BASE" \
        "$@")
    wait_for_status $CONTAINER_NAME http_call $HTTP_ADDR
    setup_awsvpc
    populate_router
}

setup_awsvpc() {
    if [ -n "$AWSVPC" ]; then
        # Set proxy_arp on the bridge, so that it could accept packets destined
        # to containers within the same subnet but running on remote hosts.
        # Without it, exact routes on each container are required.
        echo 1 >/proc/sys/net/ipv4/conf/$BRIDGE/proxy_arp
        # Avoid delaying the first ARP request. Also, setting it to 0 avoids
        # placing the request into a bounded queue as it can be seen:
        # https://git.kernel.org/cgit/linux/kernel/git/stable/linux-stable.git/tree/net/ipv4/arp.c?id=refs/tags/v4.6.1#n819
        echo 0 >/proc/sys/net/ipv4/neigh/$BRIDGE/proxy_delay
        expose_ip
    fi
}

# Recreate the parameter values that are set when the router is first launched
fetch_router_args() {
    CONTAINER_ARGS=$(docker inspect -f '{{.Args}}' $CONTAINER_NAME) || return 1
    NO_DNS_OPT=$(echo $CONTAINER_ARGS | grep -o -e '--no-dns') || true
}

populate_router() {
    if [ -z "$NO_DNS_OPT" ] ; then
        # Tell the newly-started weaveDNS about existing weave IPs
        for CONTAINER in $(docker ps -q --no-trunc) ; do
            if CONTAINER_IPS=$(with_container_addresses echo_ips $CONTAINER) && [ -n "$CONTAINER_IPS" ] ; then
                with_container_fqdn $CONTAINER put_dns_fqdn $CONTAINER_IPS
            fi
        done
    fi
}

stop_router() {
    stop $CONTAINER_NAME "Weave"
    conntrack -D -p udp --dport $PORT >/dev/null 2>&1 || true
}

launch_proxy() {
    # Set WEAVEPROXY_DOCKER_ARGS in the environment in order to supply
    # additional parameters, such as resource limits, to docker
    # when launching the weaveproxy container.
    docker_client_args $DOCKER_CLIENT_ARGS
    proxy_args "$@"
    mkdir -p /var/run/weave
    # Create a data-only container to mount the weavewait files from
    if ! docker inspect -f ' ' $VOLUMES_CONTAINER_NAME > /dev/null 2>&1 ; then
       protect_against_docker_hang
       docker create -v /w -v /w-noop -v /w-nomcast --name=$VOLUMES_CONTAINER_NAME \
           --label=weavevolumes --entrypoint=/bin/false $EXEC_IMAGE >/dev/null
    fi
    detect_awsvpc
    [ -n "$AWSVPC" ] && PROXY_ARGS="$PROXY_ARGS --no-multicast-route"
    PROXY_CONTAINER=$(docker run -d --name=$PROXY_CONTAINER_NAME \
        $(docker_run_options) \
        $RESTART_POLICY \
        --pid=host \
        $PROXY_VOLUMES \
        --volumes-from $VOLUMES_CONTAINER_NAME \
        -v /var/run/weave:/var/run/weave \
        -e DOCKER_BRIDGE \
        -e WEAVE_DEBUG \
        -e COVERAGE \
        -e WEAVE_HTTP_ADDR \
        -e EXEC_IMAGE=$EXEC_IMAGE \
        --entrypoint=/home/weave/weaveproxy \
        $WEAVEPROXY_DOCKER_ARGS $EXEC_IMAGE $COVERAGE_ARGS $PROXY_ARGS)
    wait_for_status $PROXY_CONTAINER_NAME http_call_unix $PROXY_CONTAINER_NAME status.sock
}

stop_proxy() {
    warn_if_stopping_proxy_in_env
    stop $PROXY_CONTAINER_NAME "Proxy"
}

launch_plugin_if_not_running() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-restart)
                RESTART_POLICY=
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    retval=0
    check_not_running plugin $PLUGIN_CONTAINER_NAME $BASE_PLUGIN_IMAGE || retval=$?
    # If an existing plugin is running (we start it with restart=always), return its ID
    [ $retval = 1 ] && PLUGIN_CONTAINER=$(container_id $PLUGIN_CONTAINER_NAME) && return 0
    # Any other kind of error code from check_not_running is a failure.
    [ $retval -gt 0 ] && return $retval

    if ! PLUGIN_CONTAINER=$(docker run -d --name=$PLUGIN_CONTAINER_NAME \
        $(docker_run_options) \
        $RESTART_POLICY \
        --pid=host \
        -v /run/docker/plugins:/run/docker/plugins \
        -e WEAVE_HTTP_ADDR \
        $WEAVEPLUGIN_DOCKER_ARGS $PLUGIN_IMAGE $COVERAGE_ARGS \
        "$@") ; then
        return 1
    fi
    wait_for_status $PLUGIN_CONTAINER_NAME http_call_unix $PLUGIN_CONTAINER_NAME status.sock
    WEAVE_IPAM_SUBNET=$(call_weave GET /ipinfo/defaultsubnet)
    util_op create-plugin-network weave weavemesh $WEAVE_IPAM_SUBNET
}

plugin_disabled() {
    [ -n "$WEAVE_NO_PLUGIN" ] || ! check_docker_server_api_version 1.21
}

stop_plugin() {
    util_op remove-plugin-network weave || true
    stop $PLUGIN_CONTAINER_NAME "Plugin"
}

protect_against_docker_hang() {
    # If the plugin is not running, remove its socket so Docker doesn't try to talk to it
    if ! check_running $PLUGIN_CONTAINER_NAME 2>/dev/null ; then
        rm -f /run/docker/plugins/weave.sock /run/docker/plugins/weavemesh.sock
    fi
}

######################################################################
# argument deprecation handling
######################################################################

deprecation_warning() {
    echo "Warning: ${1%=*} is deprecated; please use $2" >&2
}

deprecation_warnings() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -password|-password=*)
                deprecation_warning $1 "--password"
                [ "$1" = "-password" ] && shift
                ;;
            --password)
                shift
                ;;
            -nickname|-nickname=*)
                deprecation_warning $1 "--nickname"
                [ "$1" = "-nickname" ] && shift
                ;;
            --nickname)
                shift
                ;;
            -nodiscovery|--nodiscovery)
                deprecation_warning $1 "--no-discovery"
                ;;
            -iprange|--iprange|-iprange=*|--iprange=*)
                deprecation_warning $1 "--ipalloc-range"
                [ ${1#--} = "iprange" ] && shift
                ;;
            --ipalloc-range)
                shift
                ;;
            -ipsubnet|--ipsubnet|-ipsubnet=*|--ipsubnet=*)
                deprecation_warning $1 "--ipalloc-default-subnet"
                [ ${1#--} = "ipsubnet" ] && shift
                ;;
            --ipalloc-default-subnet)
                shift
                ;;
            -initpeercount|--initpeercount|-initpeercount=*|--initpeercount=*)
                deprecation_warning $1 "--ipalloc-init consensus=<count>"
                [ ${1#--} = "initpeercount" ] && shift
                ;;
            --init-peer-count|--init-peer-count=*)
                deprecation_warning $1 "--ipalloc-init consensus=<count>"
                [ ${1#--} = "init-peer-count" ] && shift
                shift
                ;;
            -no-default-ipam|--no-default-ipam)
                deprecation_warning $1 "--no-default-ipalloc"
                ;;
            --with-dns)
                echo "Warning: $1 has been removed; DNS is on by default" >&2
                ;;
        esac
        shift
    done
}

######################################################################
# main (remote and --local)
######################################################################

[ $(id -u) = 0 ] || {
    echo "weave must be run as 'root' when run locally" >&2
    exit 1
}

uname -s -r | sed -n -e 's|^\([^ ]*\) \([0-9][0-9]*\)\.\([0-9][0-9]*\).*|\1 \2 \3|p' | {
    if ! read sys maj min ; then
        echo "ERROR: Unable to parse operating system version $(uname -s -r)" >&2
        exit 1
    fi

    if [ "$sys" != 'Linux' ] ; then
        echo "ERROR: Operating systems other than Linux are not supported (you have $(uname -s -r))" >&2
        exit 1
    fi

    if ! [ \( "$maj" -eq 3 -a "$min" -ge 8 \) -o "$maj" -gt 3 ] ; then
        echo "WARNING: Linux kernel version 3.8 or newer is required (you have ${maj}.${min})" >&2
    fi
}

if ! command_exists ip ; then
    echo "ERROR: ip utility is missing. Please install it." >&2
    exit 1
fi

if ! ip netns list >/dev/null 2>&1 ; then
    echo "ERROR: $(ip -V) does not support network namespaces." >&2
    echo "       Please install iproute2-ss111010 or later." >&2
    exit 1
fi

if ! command_exists nsenter ; then
    echo "ERROR: nsenter utility missing. Please install it." >&2
    exit 1
fi

[ $# -gt 0 ] || usage
COMMAND=$1
shift 1

handle_help_arg "$1"

case "$COMMAND" in
    setup)
        for img in $IMAGE $EXEC_IMAGE $PLUGIN_IMAGE $WEAVEDB_IMAGE ; do
            docker pull $img
        done
        setup_cni
        ;;
    setup-cni)
        setup_cni
        ;;
    version)
        [ $# -eq 0 ] || usage
        ask_version $CONTAINER_NAME $IMAGE || true
        ask_version $PROXY_CONTAINER_NAME $EXEC_IMAGE --entrypoint=/home/weave/weaveproxy || true
        ask_version $PLUGIN_CONTAINER_NAME $PLUGIN_IMAGE || true
        ;;
    # intentionally undocumented since it assumes knowledge of weave
    # internals
    create-bridge)
        if [ "$1" != "--force" ] ; then
            cat 1>&2 <<EOF
WARNING: 'weave create-bridge' is deprecated. Instead use 'weave attach-bridge'
to link the docker and weave bridges after both docker and weave have been
started. Note that, unlike 'weave create-bridge', 'weave attach-bridge' is
compatible with fast data path.
EOF
            # This subcommand may be run without the docker daemon, but
            # fastdp needs to run the router container to setup the ODP
            # bridge, hence:
            if [ -z "$WEAVE_NO_FASTDP" ] ; then
                cat 1>&2 <<EOF

ERROR: 'weave create-bridge' is not compatible with fast data path. If you
really want to do this please set the WEAVE_NO_FASTDP environment variable.
EOF
                exit 1
            fi
        else
            shift 1
        fi
        create_bridge --without-ethtool "$@"
        ;;
    attach-bridge)
        if detect_bridge_type ; then
            attach_bridge ${1:-$DOCKER_BRIDGE}
            insert_iptables_rule nat POSTROUTING -o $BRIDGE -j ACCEPT
        else
            echo "Weave bridge not found. Please run 'weave launch' and try again" >&2
            exit 1
        fi
        ;;
    bridge-type)
        detect_bridge_type && echo $BRIDGE_TYPE
        ;;
    launch)
        deprecation_warnings "$@"
        check_not_running router $CONTAINER_NAME        $BASE_IMAGE
        check_not_running proxy  $PROXY_CONTAINER_NAME  $BASE_EXEC_IMAGE
        check_not_running plugin $PLUGIN_CONTAINER_NAME $BASE_PLUGIN_IMAGE
        COMMON_ARGS=$(common_launch_args "$@")
        launch_router "$@"
        launch_proxy  $COMMON_ARGS
        plugin_disabled || launch_plugin_if_not_running $COMMON_ARGS
        ;;
    launch-router)
        deprecation_warnings "$@"
        check_not_running router $CONTAINER_NAME $BASE_IMAGE
        launch_router "$@"
        echo $ROUTER_CONTAINER
        ;;
    attach-router)
        check_running $CONTAINER_NAME
        enforce_docker_bridge_addr_assign_type
        # We cannot use detect_awsvpc here, because HTTP server might not be started
        ! docker inspect -f '{{.Config.Cmd}}' $CONTAINER_NAME | grep -q -- "--awsvpc" || AWSVPC=1
        create_bridge
        fetch_router_args
        wait_for_status $CONTAINER_NAME http_call $HTTP_ADDR
        setup_awsvpc
        populate_router
        ;;
    launch-proxy)
        deprecation_warnings "$@"
        check_not_running proxy $PROXY_CONTAINER_NAME $BASE_EXEC_IMAGE
        launch_proxy "$@"
        echo $PROXY_CONTAINER
        ;;
    launch-plugin)
        if ! check_running $CONTAINER_NAME 2>/dev/null ; then
            echo "ERROR:" $CONTAINER_NAME "container must be running before plugin can be launched" >&2
            exit 1
        fi
        launch_plugin_if_not_running "$@"
        echo $PLUGIN_CONTAINER
        ;;
    env|proxy-env)
        [ "$COMMAND" = "env" ] || deprecation_warning "$COMMAND" "'weave env'"
        if PROXY_ADDR=$(proxy_addr) ; then
            [ "$PROXY_ADDR" = "$DOCKER_CLIENT_HOST" ] || RESTORE="ORIG_DOCKER_HOST=$DOCKER_CLIENT_HOST"
            echo "export DOCKER_HOST=$PROXY_ADDR $RESTORE"
        fi
        ;;
    config|proxy-config)
        [ "$COMMAND" = "config" ] || deprecation_warning "$COMMAND" "'weave config'"
        PROXY_ADDR=$(proxy_addr) && echo "-H=$PROXY_ADDR"
        ;;
    connect)
        [ $# -gt 0 ] || usage
        [ "$1" = "--replace" ] && replace="-d replace=true" && shift
        call_weave POST /connect $replace -d $(peer_args "$@")
        ;;
    forget)
        [ $# -gt 0 ] || usage
        call_weave POST /forget -d $(peer_args "$@")
        ;;
    status)
        res=0
        SUB_STATUS=
        STATUS_URL="/status"
        SUB_COMMAND="$@"
        while [ $# -gt 0 ] ; do
            SUB_STATUS=1
            STATUS_URL="$STATUS_URL/$1"
            shift
        done
        [ -n "$SUB_STATUS" ] || echo
        call_weave GET $STATUS_URL || res=$?
        if [ $res -eq 4 ] ; then
            echo "Invalid 'weave status' sub-command: $SUB_COMMAND" >&2
            usage
        fi
        if [ -z "$SUB_STATUS" ] && check_running $PROXY_CONTAINER_NAME 2>/dev/null && PROXY_ADDRS=$(proxy_addrs) ; then
            echo
            echo "        Service: proxy"
            echo "        Address: $PROXY_ADDRS"
        fi
        if [ -z "$SUB_STATUS" ] && check_running $PLUGIN_CONTAINER_NAME 2>/dev/null ; then
            echo
            echo "        Service: plugin"
            echo "     DriverName: weave"
        fi
        [ -n "$SUB_STATUS" ] || echo
        [ $res -eq 0 ]
        ;;
    report)
        if [ $# -gt 0 ] ; then
            [ $# -eq 2 -a "$1" = "-f" ] || usage
            call_weave GET /report --get --data-urlencode "format=$2"
        else
            call_weave GET /report -H 'Accept: application/json'
        fi
        ;;
    run)
        dns_args "$@"
        shift $(dns_arg_count "$@")
        REWRITE_HOSTS=1
        NO_MULTICAST_ROUTE=
        while [ $# -gt 0 ]; do
            case "$1" in
                --no-rewrite-hosts)
                    REWRITE_HOSTS=
                    ;;
                --no-multicast-route)
                    NO_MULTICAST_ROUTE=1
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        CONTAINER=$(docker run -e WEAVE_CIDR=none $DNS_ARGS -d "$@")
        create_bridge
        ipam_cidrs_or_die allocate $CONTAINER $CIDR_ARGS
        [ -n "$REWRITE_HOSTS" ] && extra_hosts_args "$@" && rewrite_etc_hosts $DNS_EXTRA_HOSTS
        do_or_die $CONTAINER attach $ALL_CIDRS
        when_weave_running with_container_fqdn $CONTAINER put_dns_fqdn $ALL_CIDRS
        echo $CONTAINER
        ;;
    dns-args)
        dns_args "$@"
        echo -n $DNS_ARGS
        ;;
    docker-bridge-ip)
        util_op bridge-ip $DOCKER_BRIDGE
        ;;
    start)
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        [ $# -eq 1 ] || usage
        RES=$(docker start $1)
        CONTAINER=$(container_id $1)
        create_bridge
        ipam_cidrs_or_die allocate $CONTAINER $CIDR_ARGS
        do_or_die $CONTAINER attach $ALL_CIDRS
        when_weave_running with_container_fqdn $CONTAINER put_dns_fqdn $ALL_CIDRS
        echo $RES
        ;;
    attach)
        DNS_EXTRA_HOSTS=
        REWRITE_HOSTS=
        NO_MULTICAST_ROUTE=
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        while [ $# -gt 0 ]; do
            case "$1" in
                --rewrite-hosts)
                    REWRITE_HOSTS=1
                    ;;
                --add-host)
                    DNS_EXTRA_HOSTS="$2 $DNS_EXTRA_HOSTS"
                    shift
                    ;;
                --add-host=*)
                    DNS_EXTRA_HOSTS="${1#*=} $DNS_EXTRA_HOSTS"
                    ;;
                --no-multicast-route)
                    NO_MULTICAST_ROUTE=1
                    ;;
                *)
                    break
                    ;;
            esac
            shift
        done
        [ $# -eq 1 ] || usage
        CONTAINER=$(container_id $1)
        create_bridge
        ipam_cidrs allocate $CONTAINER $CIDR_ARGS
        [ -n "$REWRITE_HOSTS" ] && rewrite_etc_hosts $DNS_EXTRA_HOSTS
        attach $ALL_CIDRS >/dev/null
        when_weave_running with_container_fqdn $CONTAINER put_dns_fqdn $ALL_CIDRS
        show_addrs $ALL_CIDRS
        ;;
    detach)
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        [ $# -eq 1 ] || usage
        CONTAINER=$(container_id $1)
        ipam_cidrs lookup $CONTAINER $CIDR_ARGS
        util_op detach-container $CONTAINER $ALL_CIDRS >/dev/null
        when_weave_running with_container_fqdn $CONTAINER delete_dns_fqdn $ALL_CIDRS
        for CIDR in $IPAM_CIDRS ; do
            call_weave DELETE /ip/$CONTAINER/${CIDR%/*}
        done
        show_addrs $ALL_CIDRS
        ;;
    restart)
        [ $# -ge 1 ] || usage
        create_bridge
        ALL_CIDRS=$(with_container_addresses echo_cidrs $1)
        RES=$(docker restart $1)
        CONTAINER=$(container_id $1)
        for CIDR in $ALL_CIDRS ; do
            call_weave PUT /ip/$CONTAINER/$CIDR?check-alive=true
        done
        detect_awsvpc
        do_or_die $CONTAINER attach $ALL_CIDRS
        when_weave_running with_container_fqdn $CONTAINER put_dns_fqdn $ALL_CIDRS
        echo $RES
        ;;
    dns-add)
        collect_dns_add_remove_args "$@"
        FN=put_dns_fqdn
        [ -z "$CONTAINER" ] && CONTAINER=weave:extern && FN=put_dns_fqdn_no_check_alive
        if [ -n "$FQDN" ] ; then
            $FN $CONTAINER $FQDN $IP_ARGS
        else
            with_container_fqdn $CONTAINER $FN $IP_ARGS
        fi
        ;;
    dns-remove)
        collect_dns_add_remove_args "$@"
        [ -z "$CONTAINER" ] && CONTAINER=weave:extern
        if [ -n "$FQDN" ] ; then
            delete_dns_fqdn $CONTAINER $FQDN $IP_ARGS
        else
            delete_dns $CONTAINER $IP_ARGS
        fi
        ;;
    dns-lookup)
        [ $# -eq 1 ] || usage
        DOCKER_BRIDGE_IP=$(util_op bridge-ip $DOCKER_BRIDGE)
        dig @$DOCKER_BRIDGE_IP +short $1
        ;;
    expose)
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        if [ $# -eq 0 ] ; then
            FQDN=""
        else
            [ $# -eq 2 -a "$1" = "-h" ] || usage
            FQDN="$2"
        fi
        create_bridge --without-ethtool
        expose_ip
        util_op expose-nat $ALL_CIDRS
        show_addrs $ALL_CIDRS
        ;;
    hide)
        collect_cidr_args "$@"
        shift $CIDR_ARG_COUNT
        ipam_cidrs lookup weave:expose $CIDR_ARGS
        create_bridge --without-ethtool
        for CIDR in $ALL_CIDRS ; do
            if ip addr show dev $BRIDGE | grep -qF $CIDR ; then
                ip addr del dev $BRIDGE $CIDR
                delete_iptables_rule nat WEAVE -d $CIDR ! -s $CIDR -j MASQUERADE
                delete_iptables_rule nat WEAVE -s $CIDR ! -d $CIDR -j MASQUERADE
                when_weave_running delete_dns weave:expose $CIDR
            fi
        done
        for CIDR in $IPAM_CIDRS ; do
            call_weave DELETE /ip/weave:expose/${CIDR%/*}
        done
        show_addrs $ALL_CIDRS
        ;;
    ps)
        [ $# -eq 0 ] && CONTAINERS="weave:expose $(docker ps -q)" || CONTAINERS="$@"
        with_container_addresses echo_addresses $CONTAINERS
        ;;
    stop)
        [ $# -eq 0 ] || usage
        plugin_disabled || stop_plugin
        stop_router
        stop_proxy
        ;;
    stop-router)
        [ $# -eq 0 ] || usage
        stop_router
        ;;
    stop-proxy)
        [ $# -eq 0 ] || usage
        stop_proxy
        ;;
    stop-plugin)
        [ $# -eq 0 ] || usage
        stop_plugin
        ;;
    reset)
        [ $# -eq 0 ] || [ $# -eq 1 -a "$1" = "--force" ] || usage
        plugin_disabled || util_op remove-plugin-network weave || true
        warn_if_stopping_proxy_in_env
        res=0
        [ "$1" = "--force" ] || check_running $CONTAINER_NAME 2>/dev/null || res=$?
        case $res in
            0)
                call_weave DELETE /peer >/dev/null 2>&1 || true
                fractional_sleep 0.5 # Allow some time for broadcast updates to go out
                ;;
            1)
                # No such container; assume user already did reset
                ;;
            2)
                echo "ERROR: weave is not running; unable to remove from cluster." >&2
                echo "Re-launch weave before reset or use --force to override." >&2
                exit 1
                ;;
        esac
        for NAME in $PLUGIN_CONTAINER_NAME $CONTAINER_NAME $PROXY_CONTAINER_NAME ; do
            docker stop  $NAME >/dev/null 2>&1 || true
            docker rm -f $NAME >/dev/null 2>&1 || true
        done
        protect_against_docker_hang
        VOLUME_CONTAINERS=$(docker ps -qa --filter label=weavevolumes)
        [ -n "$VOLUME_CONTAINERS" ] && docker rm -v $VOLUME_CONTAINERS  >/dev/null 2>&1 || true
        conntrack -D -p udp --dport $PORT >/dev/null 2>&1 || true
        destroy_bridge
        for LOCAL_IFNAME in $(ip link show | grep v${CONTAINER_IFNAME}pl | cut -d ' ' -f 2 | tr -d ':') ; do
            ip link del ${LOCAL_IFNAME%@*} >/dev/null 2>&1 || true
        done
        ;;
    rmpeer)
        [ $# -gt 0 ] || usage
        res=0
        for PEER in "$@" ; do
            call_weave DELETE /peer/$PEER || res=1
        done
        [ $res -eq 0 ]
        ;;
    launch-dns)
        echo "The 'launch-dns' command has been removed; DNS is launched as part of 'launch' and 'launch-router'." >&2
        exit 0
        ;;
    stop-dns)
        echo "The 'stop-dns command has been removed; DNS is stopped as part of 'stop' and 'stop-router'." >&2
        exit 0
        ;;
    prime)
        call_weave GET /ring
        ;;
    *)
        echo "Unknown weave command '$COMMAND'" >&2
        usage
        ;;
esac