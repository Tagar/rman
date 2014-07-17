
#----------------------------------------------------------------------------
# ********* RMAN backups script	low-level subroutines rman_backup.ksh.subs **
#
# This subscript includes low-level functions used by rman_backup.ksh
#
#

# ******** Functions:								***************


#-------------------------------------------

function archive_log_current {
	if [ "x$DB_ROLE" = "xSTANDBY" ]; then
		#If we are here, then it is a standby database.
		#TODO: check. looks like 11.2.0.4+ tries to switchlog on primary automatically!?
		dosql pridb 'SELECT PRIMARY_DB_UNIQUE_NAME FROM V$DATABASE'
		if [ "x$pridb" = "x" ]; then
			echo "WARN: There is no value in v$database.PRIMARY_DB_UNIQUE_NAME for $db database."
			echo "Did this database ever received redo from primary database? Read http://goo.gl/CiV9Tl for PRIMARY_DB_UNIQUE_NAME"
			echo "Continuing backup, but *** THIS HAS TO BE FIXED ***"
			return
		fi
		echo "INFO: Current primary database is $pridb. Will issue ALTER SYSTEM ARCHIVE LOG CURRENT there."
		dblogin="/@$pridb as sysdba"	#assuming you already saved Oracle Wallet for this currently primary database for user SYS
	else
		#it's primary, so archive log switch should be done locally.
		unset dblogin
	fi
	dosql noreturn "ALTER SYSTEM ARCHIVE LOG CURRENT" "$dblogin"
	#TODO: ORA-16014: log xx sequence# xxx not archived, no available destinations
	#	 	should be ignored (especially for MODE=ARCH - archive log backups)
	#		This could happen e.g. if there is no space available but we 
	#				have to run arch log backup anyway...
}

#----------------------------------------------------------------------------

function dosql {
	typeset -n retvar=$1
	login=${3:-/as sysdba}
	[ $BACKUP_DEBUG -eq 1 ] && echo "DEBUG: sqlplus $login about to run: $2"
	retvar=$( $ORACLE_HOME/bin/sqlplus -S "$login" <<EOF
whenever sqlerror exit 5;
set echo off head off feed off newpage none pagesize 1000 linesize 200
$2;
exit;
EOF
		)
	if [ $? -eq 5 ] ; then
		echo "ERROR: RMAN-00000: sqlplus returned error for SQL: $2"
		echo "$retvar"
		retvar=
	else
		[ $BACKUP_DEBUG -eq 1 ] && echo "DEBUG: sqlplus returned $retvar"
	fi
}

#-------------------------------------------

function get_database_info
{	#1. get Oracle release number
	dosql Release "SELECT SUBSTR(V,1,INSTR(v,'.')-1) FROM (SELECT MIN(V) V FROM (SELECT distinct(version) v FROM PRODUCT_COMPONENT_VERSION))"
	echo "INFO: Major release of the database $db is $Release."
	Ver10up=1
	if [ "$Release" -le "9" ] ; then
		Ver10up=0
		echo "INFO: FRA is not supported in Oracle 9."
	fi

	#2. get database DG role
	#-- cut out first word - e.g. "physical" and keep only 'PRIMARY' or 'STANDBY'
	dosql DB_ROLE "select SUBSTR(r,INSTR(r,' ')+1) from (select database_role r from v\$database)"
	echo "INFO: Database Role: $DB_ROLE"
}

function report_backup_size
{	[ $Ver10up -ne 1 ] && return 0		#V$RMAN_OUTPUT and V$RMAN_STATUS are 10g+

	#1. Get the first backup piece handle. Line format is different in debug and non-debug mode, e.g. respectively:
	#RMAN-08530: piece handle=igp6dj9m_1_1 tag=ARCH_LOGS comment=API Version 2.0,MMS Version 9.0.0.84
	#piece handle=dip6a1do_1_1 tag=ARCH_LOGS comment=API Version 2.0,MMS Version 9.0.0.84
	handle=`egrep "^(RMAN-08530: )?piece handle=" $LOGFILE | head -n 1 | cut -d "=" -f 2 | cut -d " " -f 1`
	if [ "x$handle" = "x" ] ; then
		[ $BACKUP_DEBUG -eq 1 ] && echo "DEBUG: report_backup_size: can't find piece handle in the log file."
		return
	fi

	#2. Query parent (session/rman) row from $RMAN_STATUS for the total backup size.
	dosql used_mb "variable handle VARCHAR2(32);
begin  :handle := '$handle';
end;
/
	WITH q AS (
        SELECT /*+ rule */
                 ROUND(SUM(INPUT_BYTES)/1024/1024,1) inp_mb, ROUND(SUM(OUTPUT_BYTES)/1024/1024,1) out_mb
        FROM V\$RMAN_STATUS 
        WHERE ROW_TYPE='SESSION' and OPERATION='RMAN'
        START WITH (RECID, STAMP) =
              --(SELECT MAX(session_recid),MAX(session_stamp) FROM V\$RMAN_OUTPUT)
			  (SELECT /*+ rule */ s2.parent_recid, s2.parent_stamp 
               FROM sys.V_\$BACKUP_PIECE p JOIN V\$RMAN_STATUS s2 ON (p.rman_status_recid=s2.recid AND p.rman_status_stamp=s2.stamp) 
				WHERE handle=:handle)
        CONNECT BY PRIOR RECID = PARENT_RECID AND PRIOR STAMP = PARENT_STAMP
	) SELECT  'Backed up '||inp_mb ||' Mb of data'
        ||CASE WHEN out_mb>0.1 and inp_mb/out_mb>1.02 THEN ' (output size is '||out_mb||' Mb)' END
        ||'.' as size_msg 
	FROM q"
	#Reported output size is smaller for incremental backups and/or for backups with enabled compression.
	echo "INFO: $used_mb"
}

function check_best_practices {
	dosql ctlf_record_keep_time "select value from v\$parameter where name='control_file_record_keep_time'"
	if [ "$ctlf_record_keep_time" -lt $(( $RECOVERY_WINDOW +10 )) ] ; then
		echo "WARN: CONTROL_FILE_RECORD_KEEP_TIME init parameter is $ctlf_record_keep_time is too low."
		echo "WARN: Recommended value is $(( $RECOVERY_WINDOW +10 )) based on your recovery window and Oracle Note 829755.1."
		if [ "$FIX_BEST_PRACTICES" -eq "1" ] ; then
			dosql noreturn "ALTER SYSTEM SET CONTROL_FILE_RECORD_KEEP_TIME=$(( $RECOVERY_WINDOW +10 )) scope=BOTH"
			echo "WARN: Fixed!"
		fi
	fi
}


#-------------------------------------------

function check_FRA {
	NO_FRA="10"			#no fra return code
	FRA_THRESHOLD=$1	#first parameter

	[ $Ver10up -ne 1 ] && return 0		#there is no FRA in pre-10g

	dosql FRA_PRC_USED_SOFT 'SELECT round(space_used*100/space_limit,0) pct FROM V$RECOVERY_FILE_DEST'
	dosql FRA_PRC_USED_HARD 'SELECT round((space_used-space_reclaimable)*100/space_limit,0) pct FROM V$RECOVERY_FILE_DEST'

	if [ "x$FRA_PRC_USED_SOFT" = "x" ] ; then
		echo "ERROR: Can't detect Flash Recovery Area for $db."
		email "Can not detect FRA" <<EMAIL
		Can't detect Flash Recovery Area for $db.
		
		The DB_RECOVERY_FILE_DEST and DB_RECOVERY_FILE_DEST_SIZE init params must be set.
		
		http://download.oracle.com/docs/cd/B19306_01/backup.102/b14192/setup005.htm : 
			"Use of the flash recovery area is STRONGLY recommended"
EMAIL
		return $NO_FRA
	fi
	echo "INFO: FLASH RECOVERY AREA is ${FRA_PRC_USED_SOFT}% FULL (including reclaimable space)"
	echo "INFO: FLASH RECOVERY AREA is ${FRA_PRC_USED_HARD}% FULL (minus reclaimable space)"
	if [ $FRA_PRC_USED_HARD -ge $FRA_THRESHOLD ] ; then
		dosql FRA_USAGE 'set head on echo on
                SELECT * FROM V$FLASH_RECOVERY_AREA_USAGE'
		email "flash_recovery_area is ${FRA_PRC_USED_HARD}% FULL" <<EMAIL
		This is a WARNING.
		FLASH RECOVERY AREA of $db@`hostname` database is ${FRA_PRC_USED_HARD}% FULL.

		Components consuming recovery area space:
$FRA_USAGE
EMAIL
	fi
}

#-------------------------------------------

function email {
	subject=$1
	mailx -s "$db@`hostname` $subject *****" $DBA_EMAIL
	echo "INFO: email with subject '$subject' sent to $DBA_EMAIL at `date`"
}

#-------------------------------------------

function check_and_email_results {
	rman_ignore_regex="WARNING: |RMAN-005(69|71): ==="
	#List of RMAN errors to ignore: 1) all warnings;
	#and 2) RMAN-00571 and RMAN-00569 are just used for RMAN error stack header (formatting)

	#3) for Commvault, also ignore RMAN-06525: RMAN retention policy is set to none
	#					and RMAN-03002: failure of report command
	[ "x$BACKUP_TYPE" = 'xCommvault' ] &&
		rman_ignore_regex="$rman_ignore_regex|RMAN-0(3002|6525)"

	[ $BACKUP_DEBUG -eq 1 ] && echo "DEBUG: RMAN errors to ignore regexp=$rman_ignore_regex"

	#count number of RMAN errors:
	errcount=`egrep "RMAN-[0-9]" $LOGFILE | egrep -v "$rman_ignore_regex" |wc -l`
	if [ $errcount -ne 0 ] ; then
		echo "Errors ($errcount) detected in $db rman backup"
		email "RMAN errors" <<EMAIL
	Log file $LOGFILE
	Errors:
`egrep "(RMAN|ORA)-[0-9]" $LOGFILE | egrep -v "$rman_ignore_regex" |tail -n 15`

	RMAN script used:
	$SCRIPT

First 200 lines from the log file:

`head -n 200 $LOGFILE`

....
EMAIL
		return
	fi

	#rest of the subroutine assumes no RMAN/ORA errors
	case $MODE in
		ARCH|CTRL)		;;	#no "ok" emails for archived logs and control file backups
		XCHK) #email for crosscheck and report results:
				email "IMPORTANT: database recoverability reports!" <<EMAIL
Here are the main reports that show database recoverability and RMAN backups status:

`egrep -v "found to be 'AVAILABLE'|backup piece handle=|validation succeeded for archived log|archived log file name=" $LOGFILE`

For more details look at log file $LOGFILE on `hostname`.
EMAIL
			;;
		*)	#email for all normal FULL/INCR backups:
				#wc with redirection (<) does not print file name vs argumented filename
				if [ `wc -l < $LOGFILE` -le 350 ] ; then
					#If log file is smaller than 350 lines, email it completely:
					email "RMAN backup complete" <<EMAIL
Complete contents of the log file $LOGFILE:
`cat $LOGFILE`
EMAIL
				else
					email "RMAN backup complete" <<EMAIL
First 200 and last 100 lines from log file $LOGFILE:
`head -n 200 $LOGFILE`

....

`tail -n 100 $LOGFILE`
EMAIL
				fi
			;;
	esac
}

#-------------------------------------------

#This function is used to limit RMAN's ability to hog CPU
# (especially helpful when used with bzip2 compression - 10g default)
function renice_rman {
	sleep $RENICE_WAIT	#wait for all rman channels to start up
	dosql PIDS "
		select p.spid  from  v\$session s join v\$process p on (s.paddr = p.addr)
		where  lower(s.client_info) like 'rman%'
		   and lower(s.program)     like 'rman@%'  
		   and lower(s.module)      like 'backup%'
		   and s.logon_time>sysdate-($RENICE_WAIT+120)/86400"
	case `uname` in
		Linux) PIDS2=`echo -n "$PIDS" | tr "\n" ","`	;;
		*)	   PIDS2=`echo "$PIDS\c" | tr "\n" ","`		;;
	esac

	if [ "x$PIDS2" = "x" ]; then
		echo "WARN: renice_rman() could not detect active RMAN sessions. RENICE_WAIT is too small?"
	else
		echo $PIDS | xargs $RENICE
		echo "INFO: Reniced Oracle processes participating in RMAN backup to lower priority."
		echo "List of RMAN related processes with PIDs $PIDS2:"
		ps -o pid,nice,user,time,comm,args -p $PIDS2
	fi
}

#-------------------------------------------

function check_simul_run {
	rmans=`ps -ef | grep "rman/rman_backup.ksh" | egrep -v " (grep|$$|XCHK) " | wc -l`
	# $$ - assuming default ps -ef prints both pid and ppid
	# XCHK - is normally a long-running process that is okay to run with archived log backups

	if [ $rmans -gt 1 ] ; then
                echo "WARNING: more than 1 active RMAN script is running"
                email "RMAN scripts schedule overlap" <<EMAIL
        Log file $LOGFILE0
	ARCH backup - exiting...
        Other RMAN scripts running: $rmans
`ps -ef | grep "rman/rman_backup.ksh" | egrep -v " (grep|$$|XCHK) "`
EMAIL
		exit 1
	fi
}

#-------------------------------------------

function report_runtime {
	S2=$SECONDS
	typeset -i minutes
	minutes=$(( ($S2 - $S1)/60 ))
	seconds=$(( ($S2 - $S1)%60 ))
	echo "== Backup script took $minutes minutes $seconds seconds to complete."
}

#-------------------------------------------

function parse_params {
	eval set -A params $(echo $db | tr ':' ' ')
	db=${params[0]}
	DG=${params[1]}
}

#-------------------------------------------

function remove_old_files {
	echo "Deleting old log files..."
	find $BASE_PATH/log \(    -mtime +65 -name "rmanbackup*.log" \
						   -o -mtime +4  -name "rmanbackup*.rman-trace" \
						 \) -print -exec rm {} \;
	find $BASE_PATH/scripts \(   -mtime +65 -name "rmanclone_*.sh" \
						   -o -mtime +35  -name "controlf-*.ctl-bkpcopy" \
						   -o -mtime +65  -name "*.*-bkpcopy" \
						 \) -print -exec rm {} \;
}

#-------------------------------------------

function generate_clone_script {
	#See http://docs.oracle.com/cd/B19306_01/backup.102/b14191/rcmdupdb.htm#i1008888

	unset RMAN_CHANNELS RMAN_RELEASE_CHANNELS
	prepare_channels 2 AUXILIARY
	
	#In all below SQLs 
	#   DECODE(SUBSTR(d.name,1,1), '+', SUBSTR(d.name,1,INSTR(d.name,'/')-1), d.name||'-new')
	#used to leave on DG part if ASM is used, otherwise adds "-new" to a filename
	
	dosql CLONE_DATANAMES "SELECT '	SET NEWNAME FOR DATAFILE '''||d.name||''' to '''||
			DECODE(SUBSTR(d.name,1,1), '+', SUBSTR(d.name,1,INSTR(d.name,'/')-1), d.name||'-new')
			||''';  -- '||t.name||', datafile#'||file#    
		FROM v\$datafile d JOIN v\$tablespace t ON (t.ts#=d.ts#)  
		ORDER BY t.name, file#"
	dosql CLONE_TEMPNAMES "SELECT '	SET NEWNAME FOR TEMPFILE '''||name||''' to '''||
			DECODE(SUBSTR(name,1,1), '+', SUBSTR(name,1,INSTR(name,'/')-1), name||'-new')
			||''';  -- tempfile#'||file#  
		FROM v\$tempfile ORDER BY file#;
		
		select '	SET UNTIL TIME \"to_date('''||to_char(SYSDATE,'Mon DD YYYY HH24:MI:SS')||''',''Mon DD YYYY HH24:MI:SS'')\";' from dual"
	dosql CLONE_LOGNAMES "SET SERVEROUTPUT ON size 100000
DECLARE		l_member pls_integer := 1;  -- current member # in a group  
BEGIN
        dbms_output.put_line('	LOGFILE ');
        FOR r IN (SELECT lf.group#, l.bytes/1024/1024 mb, l.members
                       , DECODE(SUBSTR(lf.member,1,1), '+', SUBSTR(lf.member,1,INSTR(lf.member,'/')-1), lf.member||'-new') f
                  FROM v\$logfile lf, v\$log l 
                  WHERE lf.group# = l.group# AND lf.type='ONLINE'   -- skip standby logs
                  ORDER BY lf.group#, member)
        LOOP    dbms_output.put( CASE WHEN l_member=1 THEN 
									case when r.group#=1 then  '	  ' else '	, ' end 
									|| 'GROUP ' || TO_CHAR(r.group#) || ' ('
								 ELSE   ', '
								 END         || ''''||r.f||'''');
                l_member := l_member +1;
                IF l_member -1 = r.members THEN
                        dbms_output.put_line(') SIZE ' || TO_CHAR(r.mb) || 'M ');
                        l_member := 1;
                END IF;
        END LOOP;
END;
/
select null from dual where 1=0
"

	clone_script=$BASE_PATH/scripts/rmanclone_${db}_`date '+%Y%m%d'`.sh
	cat <<CLONESCRIPT > $clone_script
#!/bin/sh

{
export ORACLE_SID=${db}new
export ORAENV_ASK=NO
. oraenv

#-- target is source database ($db) to be cloned
#-- auxiliary is a new database (${db}new) cloned out of target database

\$ORACLE_HOME/bin/rman target /@$db auxiliary / <<RMANSCRIPT
$RMAN_INIT
RUN {	$RMAN_CHANNELS

$CLONE_DATANAMES

$CLONE_TEMPNAMES

	DUPLICATE TARGET DATABASE TO ${db}new
$CLONE_LOGNAMES
	;
}
RMANSCRIPT
} 2>&1 > $clone_script.log

CLONESCRIPT
	echo "INFO: RMAN clone script generated as $clone_script"
}

#----------------------------------------------------------------------------

function prepare_channels {
	if [ $Ver10up -ne 1 ]; then
		#For 9i databases only (no FRA):
		mkdir -p $ONDISK_LOCATION/$db
		eval "CH_FORMAT=\"FORMAT '$BACKUP_FORMAT'\""		#eval() to expand $db and $tags
	fi

	c=1; while [[ $c -le $1 ]]
	do
		RMAN_CHANNELS="$RMAN_CHANNELS
			ALLOCATE $2 CHANNEL ch$c $ALLOCATE_PARMS $CH_FORMAT;
			SETLIMIT CHANNEL ch$c $CHANNEL_SETLIMIT;"
		RMAN_RELEASE_CHANNELS="$RMAN_RELEASE_CHANNELS
			RELEASE CHANNEL ch$c;"
		(( c=c+1 ))
	done
}

#maintenance channels are used by CHANGE, DELETE and CROSSCHECK commands.
function prepare_maintenance_channels {
	#see ML Note 567555.1
	#  and http://docs.oracle.com/cd/B19306_01/backup.102/b14194/rcmsynta005.htm

	#no release for maintenance channels
	RMAN_RELEASE_CHANNELS=""

	#maintenance channel type DISK is always allocated:
	RMAN_CHANNELS="ALLOCATE CHANNEL FOR MAINTENANCE TYPE DISK;"

	if [ $BACKUP_TYPE != 'DISK' ]; then
		#SBT only if needed:
		RMAN_CHANNELS="$RMAN_CHANNELS
			ALLOCATE CHANNEL FOR MAINTENANCE $ALLOCATE_PARMS;"
	fi
}

function rman_pri_configures {
	#Read 1519386.1: RMAN-5021 this configuration cannot be changed for a BACKUP or STANDBY.
	#This could lead to standby having different retention policy from primary.
	if [ "x$DB_ROLE" != 'xPRIMARY' ]; then
		return
	fi
	SCRIPT="$RMAN_PRI_CONFIGURES
			$SCRIPT"

	if [ "x$DG" != 'xDG' ]; then
		SCRIPT="CONFIGURE ARCHIVELOG DELETION POLICY CLEAR;
					$SCRIPT"
		return
	fi

	#APPLIED ON STANDBY works on 10g/11g, but APPLIED ON ALL STANDBY is 11g only.
	#You should put any other configures into $RMAN_HEADER_SCRIPT, so it'll be applied to standby also.
	if [ "$Release" -le "10" ] ; then
		SCRIPT="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON STANDBY;
				$SCRIPT"
		#In 10g DG you also want to set following according to DOC Id 728053.1
		#alter system set "_log_deletion_policy"='ALL' scope=spfile;
	else
		SCRIPT="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
				$SCRIPT"
	fi
}

#-------------------------------------------

function reset_global_vars {
	unset DB_ROLE SCRIPT RMAN_CHANNELS RMAN_RELEASE_CHANNELS PIDS CH_FORMAT
	unset CLONE_DATANAMES CLONE_TEMPNAMES CLONE_LOGNAMES handle ctlf_record_keep_time
	unset compressed Ver10up Release FRA_PRC_USED_SOFT FRA_PRC_USED_HARD FRA_THRESHOLD pridb 
	unset p c lines S1 S2 params minutes seconds errcount rman_debug clone_script dt
	#Global variables not to clean (they don't change from a database to database): DG
	#
	PATH=$orig_PATH:$PATHS
	MODE=$orig_MODE
	#
	S1=$SECONDS
	rman_target="/"

	#Use Oracle's oraenv to set oracle environment variables for current SID
	ORACLE_SID=$db
	ORAENV_ASK=NO
	. oraenv
}
