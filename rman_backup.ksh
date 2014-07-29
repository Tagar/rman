#!/bin/ksh93

#------------------------------------------------------------------
# ********* RMAN backups script	 	rman_backup.ksh ***************
#
# See rman_backup.info for Script Functionality, Version History 
# and other documentation.
#
# Supported - Oracle releases: tested on 9i, 10g and 11g databases;
#     		- platforms: Linux, AIX 5.1+, HP-UX 11.11+;
# 			- backup destinations: On disk backups, Commvault, TSM;
# 			- RMAN catalog and non-cataloged backups are supported.
#

#Process server-specific parameters first from rman_backup.ksh.vars
#If you need to update any type of the script's behaviour - look there first.
. rman_backup_vars.ksh


#------------------------------------------------------------------
if [ $# -lt 2 ] ; then		#not given enough parameters to script
	cat <<USAGE
USAGE:  rman_backup.ksh <operation> <SID>[:DG] [<SID>[:DG] <SID>[:DG] ...]
where <operation> is one of
	- FULL - make a full DB backup, regardless day of the week.
	- INCR - make an incremental DB backup, regardless day of the week.
	- DB - full backups on Saturdays, and INCREMENTAL LEVEL 1 CUMULATIVE - other days;
	- ARCH - to backup archive logs (usually scheduled hourly).
	- XCHK - run CROSSCHECK and RMAN reports.

	<SID> may be optionallly followed by :DG which means that this is a DataGuarded database,
	and backup should run only from standby to offload primary database.
	If you do this, then add both nodes' SYS passwords to Oracle Wallet.
	
	See rman_backup.info for more information.
USAGE
	exit 1
fi


#Only for Dataguarded databases: We need to connect to primary db to archive current log.
#Oracle Wallet is used to store password for the databases. See end of this script for OW details.


#------------------------------------------------------------------
# ! no changes should be made below !
#------------------------------------------------------------------
#
# ******** Functions:								***************

#Load low-level and utility functions rman_backup.ksh.subs:
. rman_backup_subs.ksh


#------------------------------------------------------------------

function backup_control_and_spfile {
#Backs to $BASE_PATH/scripts/ 1)control file to as binary and as text script file; 2) pfile from spfile.
#Also backs as rman backup set control and sp files.
	dt="_`date '+%Y%m%d'`"
	SCRIPT="$SCRIPT
		BACKUP $compressed SPFILE INCLUDE CURRENT CONTROLFILE TAG 'sp_ctlf_$db';
		SQL \"ALTER DATABASE BACKUP CONTROLFILE TO TRACE AS ''$BASE_PATH/scripts/controlf-$db$dt.txt-bkpcopy'' REUSE\";
		SQL \"ALTER DATABASE BACKUP CONTROLFILE TO          ''$BASE_PATH/scripts/controlf-$db$dt.ctl-bkpcopy'' REUSE\";
		SQL \"CREATE PFILE=''$BASE_PATH/scripts/init$db$dt.ora-bkpcopy'' FROM SPFILE\";"
	##do resync catalog here also if DG and primary
	case "$DB_ROLE.$MODE.$USE_CATALOG" in
		PRIMARY.CTRL.1)	SCRIPT="$SCRIPT
							RESYNC CATALOG;"
	esac
}
function backup_archive_logs {
	archive_log_current	#ALTER SYSTEM ARCHIVE LOG CURRENT on PRIMARY node (or current for non-DG database)
	SCRIPT="$SCRIPT
	        BACKUP $compressed ARCHIVELOG ALL 
			$arch_backup_options TAG 'arch_logs'
			"
	if [ $Ver10up -eq 1 ]; then
		#if FRA is enabled, do not delete archived logs explicitly, use retention policy/
		#  database auto management instead, so FRA will serve as a cache for archived logs
		#  in some sense
		SCRIPT="$SCRIPT;"
	else
		#As 9i databases do not delete anything automatically...
		SCRIPT="$SCRIPT DELETE INPUT;
			DELETE OBSOLETE;"
	fi
}
function backup_database {
	SCRIPT="BACKUP $compressed $MODE DATABASE 
		 	$db_backup_options TAG '$tags';"
	backup_archive_logs
	backup_control_and_spfile
}
#-------------------------------------------
function run_the_script {
	if [ $BACKUP_DEBUG -eq 1 ]; then
		echo "DEBUG: RMAN script: $SCRIPT"
		rman_debug="$LOGFILE.rman-trace"
		echo "DEBUG: RMAN trace file: $rman_debug"
		rman_debug="DEBUG TRACE=$rman_debug"
	fi

	echo "INFO: rman target=$rman_target"
	$NICE $ORACLE_HOME/bin/rman target=$rman_target $rman_debug <<EOF
$SCRIPT
EOF
}
#-------------------------------------------
function DO_RMAN_BACKUP {
	p=$BACKUP_PARALLELISM
	case $MODE in
			ARCH)	backup_archive_logs
					#Do more frequent control file backups in case of PITR to an older incarnation:
					backup_control_and_spfile
					;;
			CTRL)	# this mode is only used in DG mode - will run control file backup on *primary* : 
					backup_control_and_spfile	;	p=1	
					;;
			*)		backup_database				;;
	esac

	prepare_channels $p
	rman_pri_configures

	SCRIPT="$RMAN_INIT
RUN {	$RMAN_HEADER_SCRIPT
$RMAN_CHANNELS
$SCRIPT
$RMAN_TRAIL_SCRIPT $RMAN_RELEASE_CHANNELS
}
"
	renice_rman &
	renice_pid=$!

	run_the_script

	kill $renice_pid >/dev/null 2>&1
}

#-------------------------------------------


function DO_BACKUP_CROSSCHECK {
#-------------------------------------------
	#This subroutine will run RMAN CROSSCHECKs and several RMAN REPORT commands.
	#What DO_BACKUP_CROSSCHECK is not about?
	#	We assume that you use FRA to manage backups according to retention policy.
	#	So it will NOT DELETE either expired nor obsolete - run them manually at your own risk.
	#	Or you may also use third-party backup solutions that enforce their own retention.
	#How this should be used best?
	#	Schedule weekly/monthly and let DBAs review carefully results email
	#	and react immediately if any discrepancy was found.

	prepare_maintenance_channels

	SCRIPT="$RMAN_INIT
$RMAN_CHANNELS
#-- Run crosschecks and then report backup pieces and archived logs found as missing.
CROSSCHECK BACKUP completed after 'SYSDATE-$RECOVERY_WINDOW-5';
LIST EXPIRED BACKUP;

CROSSCHECK ARCHIVELOG ALL completed after 'SYSDATE–$RECOVERY_WINDOW-5';
LIST EXPIRED ARCHIVELOG ALL;

#-- Report what's affected by certain NOLOGGING operations and can't be recovered
REPORT UNRECOVERABLE;

#-- What's stored more than target retention policy
REPORT OBSOLETE;

#-- Backups that need more than 1 day of archived logs to apply:
REPORT NEED BACKUP DAYS 1;
#-- Backups that need more than 7 incremental backups for recovery:
REPORT NEED BACKUP INCREMENTAL 7;

#-- Displays objects requiring backup to satisfy a recovery window-based retention policy.
REPORT NEED BACKUP RECOVERY WINDOW OF $RECOVERY_WINDOW DAYS;
$RMAN_RELEASE_CHANNELS
"
	run_the_script
}


#-------------------------------------------
function script_mode_FULL {
	MODE="INCREMENTAL LEVEL 0"
	tags='dbfiles_full'
}
function script_mode_INCR {
	MODE="INCREMENTAL LEVEL 1 $CUMULATIVE"
	tags="dbfiles_cumul"
	db_backup_options=$db_backup_incr_options
}
function script_mode_DB {
	case `date '+%u'` in
			$FULL_BKP_DAY)	script_mode_FULL ;;		#Full backup day
						*)	script_mode_INCR ;;		#all other days - incremental backup
	esac
}
function script_mode_ARCH {
	MODE="ARCH"						#archive logs only
	tags='arch_logs'
}
function script_mode_XCHK {
	MODE="XCHK"						#rman crosscheck archivelog, backup
	tags='xchk'
}


#------------------------------------------------------------------
# Start of Main part of the script
#------------------------------------------------------------------
cd $BASE_PATH; orig_PATH=$PATH
mkdir -p $BASE_PATH/log $BASE_PATH/scripts		#where we put all the log files and gererated restore scripts.

LOGFILE0=$BASE_PATH/log/rmanbackup_`date '+%Y%m'`.log
{	echo "===== Starting $* @ `date` pid=$$...."	

	case $1 in
		FULL|INCR|DB|ARCH|XCHK)	eval "script_mode_$1";;
		*)					usage;;
	esac
	orig_MODE=$MODE

	if [ "x$MODE" = "xARCH" ]; then
		#We don't want to have too many rman processes accumulating.
		#E.g. sometimes when Commvault has an issue, rman hangs and processes accumulate.
		check_simul_run			#Check that there are no other rmans that are also running.
	fi

	shift; allsids=$*
} 2>&1 >> $LOGFILE0

#------------------------------------------------------------------
# MAIN loop - through all the databases specified in command line
#------------------------------------------------------------------
for db in $allsids
do
	parse_params

	LOGFILE=$BASE_PATH/log/rmanbackup_`date '+%Y%m%d%H%M'`_${db}_$tags.log

	#-----------------------------------------------
	{	echo "===== Starting $MODE for $db @ `date`...."
		reset_global_vars
		get_database_info
		check_best_practices

		if [ "x$DG" = 'xDG' ]; then
			#for DG databases we should connect using TNS (not just target=/), see Doc ID 1604302.1
			rman_target="/@$db"

			if [ "x$DB_ROLE" = 'xPRIMARY' ]; then
					echo "INFO: $db is part of DG cluster. Standby database will be used for backup activities."

					if [ "x$MODE" = 'xXCHK' ]; then
						echo "INFO: Exiting."
						continue	#next database
					else
						echo "INFO: Backup type change: $MODE -> CTRL"
						echo "INFO: Only control file and spfile backups will run on primary instance."
						MODE="CTRL"		#primary DG db: will run only control and spfile file backups
					fi
			fi
		fi

		echo "INFO: Backup type: $MODE $DG"

		if [ "x$MODE" = 'xXCHK' ]; then
			DO_BACKUP_CROSSCHECK

		else   #-- all other (non-crosscheck) backup operations:

			if [ $BACKUP_COMPRESS -eq 1  -a  $Ver10up -eq 1 ]; then
				compressed="AS COMPRESSED BACKUPSET"
				echo "INFO: RMAN compression enabled."
			fi

			check_FRA 99				# 0. Check if FRA is defined and not full.
			if [ $? -eq $NO_FRA ] ; then	#If Flash Recovery Area is not configured, then 
				continue					#  skip this database
			fi

			DO_RMAN_BACKUP				# 1. run the RMAN backup script

			generate_clone_script		# 1.1. generate script to clone database
			report_backup_size			# 1.2. report backup size
		fi

		check_FRA $FRA_WARN_THR		# 2. check Flash Recovery Area space *after* backup - warn if 92% or more used

		report_runtime
		check_and_email_results		# 3. check for RMAN- and ORA- errors in the $LOGFILE

		echo "===== Completed $MODE for $db @ `date`."
	} 2>&1 >> $LOGFILE
	#-----------------------------------------------
# End of $allsids Loop 
done

{	echo "===== Finished @ `date` pid=$$...."	
	remove_old_files
} 2>&1 >> $LOGFILE0


#------------------------------------------------------------------
# End Main												***********
#------------------------------------------------------------------
exit 0
