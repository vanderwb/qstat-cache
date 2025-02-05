#!/bin/bash

# Read in site-config (make edits in that file)
SECONDS=0 DATAPATH= TMPPATH= QSTATBIN= GENFREQ=60
MYPATH="$( cd "$(dirname "$0")" ; pwd )"

if [[ ! -e $MYPATH/${QSCACHE_SERVER:=site}.cfg ]]; then
    echo "Fatal: No site config found for qstat-cache. ($(date))" >> $MYPATH/error.log
    exit 1
else
    source $MYPATH/${QSCACHE_SERVER}.cfg

    if [[ ! -d $TMPPATH ]]; then
        echo "Fatal: temporary storage path does not exist. ($(date))" >> $MYPATH/error.log
        exit 2
    fi

    if [[ ! -f $QSTATBIN ]]; then
        echo "Fatal: real qstat binary not found. ($(date))" >> $MYPATH/error.log
        exit 3
    fi
fi

cd $TMPPATH

function main_gen {
    # Don't run if already running
    if [[ -f qscache-pcpid ]]; then
        # If past max age, then kill last cycle since no longer useful
        PCPID=$(cat qscache-pcpid 2> /dev/null)
        
        if kill -0 $PCPID 2> /dev/null; then
            if [[ $(ps --no-headers -p $PCPID -o etimes) -ge ${MAXAGE:-300} ]]; then
                kill $PCPID
                rm -f qscache-pcpid
            fi
        else
            rm -rf qscache-pcpid qscache-$PCPID
        fi

        exit
    fi

    # Register signal handler for forced kill
    function gen_kill {
        if [[ -d $LOGPATH ]]; then
            TS=$(date '+%H.%M:%S') LOGFILE=PBS-${QSCACHE_SERVER^^}-$(date +%Y%m%d).log
            printf "%-10s %-15s %-12s %s\n" $TS "cycle=$BASHPID" "queued=n/a" "failed after exceeding ${MAXAGE:-300}s limit" >> $LOGPATH/$LOGFILE
        fi
       
        cd $TMPPATH; rm -rf qscache-$BASHPID
        exit 1
    }

    trap gen_kill SIGTERM

    echo $BASHPID > qscache-pcpid
    mkdir -p qscache-$BASHPID $DATAPATH
    cd qscache-$BASHPID

    # Get data from PBS
    QSS_TIME=$SECONDS
    $PBSPREFIX $QSTATBIN -x | sed '/^[0-9]/,$!d' | sed 's/\([0-9]\+\) b/ \1b/' > newlist-default.dat &
    $PBSPREFIX $QSTATBIN -1 -n -s -x | sed '/^[0-9]/,$!d' | sed 's/\([0-9]\+\) b/ \1b/' > newlist-info.dat &
    $PBSPREFIX $QSTATBIN -a -1 -n -s -w -x | sed '/^[0-9]/,$!d' | sed 's/\([0-9]\+\) b/ \1b/' > newlist-wide.dat &

    if [[ " $CACHEFLAGS " == *" f "* ]]; then
        $PBSPREFIX $QSTATBIN -f > joblist-full.dat &
    else
        rm -f joblist-full.dat
    fi

    if [[ " $CACHEFLAGS " == *" Fjson "* ]]; then
        # Messy sed command fixes observed JSON errors from user environment variables:
        #   1. Numbers after a number 0 (octal) that aren't strings
        #   2. Trailing decimal points in numbers
        #   3. Numbers that begin with a decimal point
        $PBSPREFIX $QSTATBIN -f -F json | sed 's/":\(0[0-9][^,]*\)/":"\1"/; s/":\([0-9]*\)\.,/":"\1\.",/; s/":\(\.[^,]*\)/":"\1"/' > joblist-fulljson.dat &
    else
        rm -f joblist-fulljson.dat
    fi

    wait

    if [[ -d $LOGPATH ]]; then
        TS=$(date '+%H.%M:%S') LOGFILE=PBS-${QSCACHE_SERVER^^}-$(date +%Y%m%d).log
        NJOBS=$(awk '$5 == "Q" {count++} END {print count}' newlist-default.dat)
        printf "%-10s %-15s %-12s %10s seconds\n" $TS "cycle=$BASHPID" "queued=$NJOBS" $((SECONDS - QSS_TIME)) >> $LOGPATH/$LOGFILE
    fi

    # Poor-man's sync
    mv newlist-wide.dat commlist-wide-nodes.dat
    mv newlist-info.dat commlist-info-nodes.dat
    mv newlist-default.dat joblist-default.dat

    # Get versions without admin comment
    grep -v '^ ' commlist-wide-nodes.dat > joblist-wide-nodes.dat &
    grep -v '^ ' commlist-info-nodes.dat > joblist-info-nodes.dat &

    wait

    # Get versions without nodelist
    sed 's|^\([0-9].*\) [^ ].*|\1|' commlist-wide-nodes.dat > commlist-wide.dat &
    sed 's|^\([0-9].*\) [^ ].*|\1|' commlist-info-nodes.dat > commlist-info.dat &
    sed 's|^\([0-9].*\) [^ ].*|\1|' joblist-wide-nodes.dat > joblist-wide.dat &
    sed 's|^\([0-9].*\) [^ ].*|\1|' joblist-info-nodes.dat > joblist-info.dat &

    wait

    # Move files to final storage
    mv *.dat $DATAPATH
    cd $TMPPATH; rm -rf qscache-pcpid qscache-$BASHPID

    # Update datestamp
    date +%s > $DATAPATH/updated
}

while [[ $SECONDS -lt 60 ]]; do
    main_gen &
    
    if [[ $DEBUG_CYCLE == true ]]; then
        break
    fi

    sleep $GENFREQ
done

wait
