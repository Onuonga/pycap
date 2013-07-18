#!/bin/bash

#IFACE=wlan0
IFACE=eth0
SCHED=qfq
ON_TIME=1
OFF_TIME=2
DEST=192.168.122.149 #kvm receiver
#DEST=192.168.15.104 Dave's laptop
#DEST=155.185.49.13
NUM_SOURCES=200

TC=`which tc`
#TC=/home/paolo/tmp/iproute2-3.5.1/tc/tc

function configure_tc {
    tc qdisc del dev $IFACE root
    #modprobe sch_qfq
    $TC qdisc add dev $IFACE root handle 1: htb default 30
    $TC class add dev $IFACE parent 1: classid 1:1 htb rate 400mbit
    $TC qdisc add dev $IFACE parent 1:1 handle 10: $SCHED

    # get everything to generate more noise
    $TC filter add dev $IFACE protocol all parent 1: prio 1 u32 match u32 0 0 \
	classid 1:1

    for ((i=1; i <= $NUM_SOURCES; i++)); do
	WEIGHT=$(( 1 + $RANDOM % ( 12 ) ))
	WEIGHT=`echo "2^$WEIGHT" | bc`
	$TC class add dev $IFACE parent 10: classid 10:$i $SCHED \
	    weight $(( 1 + ( $WEIGHT % ($NUM_SOURCES / 2) ) )) #maxpkt 65536
	$TC qdisc add dev $IFACE parent 10:$i handle $((100 + $i)): pfifo \
	    limit 500 &

	local PORT=$((4000 + $i))
	$TC filter add dev $IFACE protocol ip parent 10: prio 1 u32 match ip \
	    dport $PORT 0xffff classid 10:$i &
    done
    $TC filter add dev $IFACE protocol all parent 10: prio 3 u32 match u32 0 0 \
	classid 10:1
}

function start_on_off_source {
    local PORT=$((4000 + $1))
    nc $2 $DEST $PORT < /dev/zero &
    local PID=$!
    while true ; do
	local on_time=`echo "$ON_TIME * ($RANDOM/32767)" | bc -l`
	sleep $on_time
	kill -STOP $PID
	local off_time=`echo "$OFF_TIME * ($RANDOM/32767)" | bc -l`
	sleep $off_time
	kill -CONT $PID
    done
}

#on the destination host, something like this must be run
#for killall -9 nc
# 
#for ((i=1; i <= $NUM_SOURCES/2; i++)); do
#        nc -l $((4000 + $i)) &
#done
#for ((i=$NUM_SOURCES/2 + 1; i <= $NUM_SOURCES + 1; i++)); do
#        nc -u -l -d $((4000 + $i)) &
#done
function start_sources {
    # add also an extra non-classified source
    for ((i=1; i <= $NUM_SOURCES/2; i++)); do
	start_on_off_source $i &
    done
    for ((i=$NUM_SOURCES/2 + 1; i <= $NUM_SOURCES + 1; i++)); do
	start_on_off_source $i -u &
    done
}

function perturb_classes {
    while true; do
	FIRST=$(( 1 + ( $NUM_SOURCES * $RANDOM ) / 32767 ))
	LAST=$(( $FIRST + ( 30 * $RANDOM ) / 32767 ))
	NEW_WEIGHT=$(( 1 + $RANDOM % ( 12 ) ))
	NEW_WEIGHT=`echo "2^$NEW_WEIGHT" | bc`
	#echo $FIRST $LAST $NEW_WEIGHT

	for ((i = $FIRST; i < $NUM_SOURCES && i < $LAST; i++)); do
	    $TC class change dev $IFACE parent 10: classid 10:$i $SCHED \
		weight $NEW_WEIGHT & #maxpkt 65536 
	done
	sleep $(( $RANDOM % 3 ))
    done
}

function shutdown {
    # delete qdiscs first, so that sources becomes free to generate a
    # very high traffic while they are dying: again, to generate more
    # noise
    $TC qdisc del dev $IFACE root
    kill $(jobs -p) > /dev/null 2>&1
    killall nc > /dev/null 2>&1
}

trap "shutdown; exit" sigint

echo Configuring classes
configure_tc
echo Starting sources
start_sources
echo Starting class perturbation
perturb_classes &

echo Test running

sleep 3600

echo Shutting down
shutdown

