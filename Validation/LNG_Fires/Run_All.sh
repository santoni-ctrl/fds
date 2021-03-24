#!/bin/bash

# This script runs a set of Validation Cases on a Linux machine with a batch queuing system.
# See the file Validation/Common_Run_All.sh for more information.
export SVNROOT=`pwd`/../..
source $SVNROOT/Validation/Common_Run_All.sh

$QFDS $DEBUG -p 25  -n 5 $QUEUE -d $INDIR Croce_01.fds
$QFDS $DEBUG -p 16  -n 8 $QUEUE -d $INDIR Croce_02.fds
$QFDS $DEBUG -p 20  -n 8 $QUEUE -d $INDIR Croce_03.fds
$QFDS $DEBUG -p 25  -n 8 $QUEUE -d $INDIR Croce_04.fds
$QFDS $DEBUG -p 28  -n 8 $QUEUE -d $INDIR Croce_05.fds
$QFDS $DEBUG -p 30  -n 8 $QUEUE -d $INDIR Croce_06.fds
$QFDS $DEBUG -p 27  -n 8 $QUEUE -d $INDIR Croce_07.fds
$QFDS $DEBUG -p 22  -n 8 $QUEUE -d $INDIR Croce_08.fds
$QFDS $DEBUG -p 17  -n 6 $QUEUE -d $INDIR Croce_09.fds
$QFDS $DEBUG -p 100 -n 8 $QUEUE -d $INDIR Croce_10.fds
$QFDS $DEBUG -p 9        $QUEUE -d $INDIR Croce_11.fds
$QFDS $DEBUG -p 83  -n 8 $QUEUE -d $INDIR Croce_12.fds
$QFDS $DEBUG -p 17  -n 6 $QUEUE -d $INDIR Croce_13.fds

echo FDS cases submitted
