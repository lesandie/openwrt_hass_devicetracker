err_msg() {
    logger -t $0 -p error $@
    echo $1 1>&2
}

register_hook() {
    logger -t $0 -p debug "register_hook $@"
    if [ "$#" -ne 1 ]; then
        err_msg "register_hook missing interface"
        exit 1
    fi
    interface=$1

    hostapd_cli -i$interface -a/usr/lib/hass-tracker/push_event.sh &
}

post() {
    logger -t $0 -p debug "post $@"
    if [ "$#" -ne 1 ]; then
        err_msg "POST missing payload"
        exit 1
    fi
    payload=$1

    config_get hass_host global host
    config_get hass_token global token
    config_get hass_curl_insecure global curl_insecure

    [ -n "$hass_curl_insecure" ] && curl_param="-k"

    resp=$(curl "$hass_host/api/services/device_tracker/see" $curl_param -sfSX POST \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $hass_token" \
        --data-binary "$payload" 2>&1)

    if [ $? -eq 0 ]; then
        level=debug
    else
        level=error
    fi

    logger -t $0 -p $level "post response $resp"
}

build_payload() {
    logger -t $0 -p debug "build_payload $@"
    if [ "$#" -ne 4 ]; then
        err_msg "Invalid payload parameters"
        logger -t $0 -p warning "push_event not handled"
        exit 1
    fi
    mac=$1
    host=$2
    consider_home=$3
    source_name=$4

    echo "{\"mac\":\"$mac\",\"host_name\":\"$host\",\"consider_home\":\"$consider_home\",\"source_type\":\"router\",\"attributes\":{\"source_name\":\"$source_name\"}}"
}

get_ip() {
    ret=$(get_ip_arp $@)
    [ -z "$ret" ] && ret=$(get_ip_dhcp $@)
    echo $ret
}

get_ip_arp() {
    # get ip for mac
    grep "0x2\s\+$1" /proc/net/arp | cut -f 1 -s -d" " | grep -v '^169.254'
}

get_ip_dhcp() {
    # get ip from dhcp table
    leasefile="$(uci get dhcp.@dnsmasq[0].leasefile)"
    grep "$1" "$leasefile" | cut -f 3 -s -d" "
}

get_host_name() {
    ret=$(get_host_name_dhcp $@)
    [ -z "$ret" ] && ret=$(get_host_name_dns $@)
    [ -z "$ret" ] && ret=$(nslookup )
    echo $ret
}

get_host_name_dns() {
    # get hostname for mac
    domain="$(uci get dhcp.@dnsmasq[0].domain)"
    nslookup "$(get_ip $1)" | grep -o "name = .*$" | cut -d ' ' -f 3 | sed -e "s/\\.$domain//"
}

get_host_name_dhcp() {
    # get hostname for mac
    leasefile="$(uci get dhcp.@dnsmasq[0].leasefile)"
    grep "$1" "$leasefile" | cut -f 4 -s -d" "
}

push_event() {
    logger -t $0 -p debug "push_event $@"
    if printf "$1" | grep -E '(add|old)'; then
        # event pushed from dnsmasq. format: <add|old> <mac> <ip> <hostname>
        mac=$2
        hostname=$4
        msg="DHCP-$1"
    elif [ "$#" -eq 3 ]; then
        iface=$1
        msg=$2
        mac=$3
    elif [ "$#" -eq 4 ]; then
        # wlan1 STA-OPMODE-SMPS-MODE-CHANGED 84:c7:de:ed:be:ef off
        if [ "$2" -ne "STA-OPMODE-SMPS-MODE-CHANGED" ]; then
          err_msg "Unknown type of push_event"
          exit 1
        fi

        iface=$1
        msg=$2
        mac=$3
        status=$4
    else
        err_msg "Illegal number of push_event parameters"
        exit 1
    fi

    config_get hass_timeout_conn global timeout_conn
    config_get hass_timeout_disc global timeout_disc
    config_get hass_source_name global source_name `uci get system.@system[0].hostname`
    config_get hass_whitelist_devices global whitelist

    case $msg in
        DHCP*)
            timeout=$hass_timeout_conn
            ;;
        "AP-STA-CONNECTED")
            timeout=$hass_timeout_conn
            ;;
        "AP-STA-POLL-OK")
            timeout=$hass_timeout_conn
            ;;
        "AP-STA-DISCONNECTED")
            timeout=$hass_timeout_disc
            ;;
        "STA-OPMODE-SMPS-MODE-CHANGED")
            timeout=$hass_timeout_conn
            ;;
        *)
            logger -t $0 -p warning "push_event not handled"
            return
            ;;
    esac
# I just want only to chek for the mac address in the whitelist, and ignore the hostname and ip.
    [ -z "$hostname" ] && hostname="$(get_host_name $mac)"
    if [ -n "$hass_whitelist_devices" ] && ! array_contains "$mac" $hass_whitelist_devices; then
        logger -t $0 -p warning "push_event ignored, $hostname with $mac not in whitelist."
    else
        post $(build_payload "$mac" "$hostname" "$timeout" "$hass_source_name")
    fi
}

array_contains() {
    logger -t $0 -p debug "array_contains $@"
    for i in `seq 2 $(($#+1))`; do
        next=$(eval "echo \$$i")
        if [ "${next}" == "${1}" ]; then
            # echo "y"
            return 0
        fi
    done
    # echo "n"
    return 1
}

sync_state() {
    logger -t $0 -p debug "sync_state $@"

    config_get hass_timeout_conn global timeout_conn
    config_get hass_source_name global source_name `uci get system.@system[0].hostname`
    config_get hass_whitelist_devices global whitelist
# The same procedure as in the push_event() function
    for interface in `iw dev | grep Interface | cut -f 2 -s -d" "`; do
        maclist=`iw dev $interface station dump | grep Station | cut -f 2 -s -d" "`
        for mac in $maclist; do
            hostname="$(get_host_name $mac)"
            if [ -n "$hass_whitelist_devices" ] && ! array_contains "$mac" $hass_whitelist_devices; then
                logger -t $0 -p warning "sync_state ignored, $hostname with $mac not in whitelist."
            else
                post $(build_payload "$mac" "$hostname" "$hass_timeout_conn" "$hass_source_name") &
            fi
        done
    done
}
