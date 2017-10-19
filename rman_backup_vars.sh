
#------------------------------------------------------------------
# ********* RMAN backups script variables  rman_backup_vars.ksh ***
#
#	This file stores all site/server-specific variables.
#

BACKUP_TYPE="DISK"					#one of: DISK, Commvault or TSM
USE_CATALOG=1						#one of: 0 or 1 (if you use RMAN Catalog)
BACKUP_COMPRESS=0					#one of: 0 or 1 (to turn on RMAN backup compression)
CUMULATIVE=1						#one of: 0 or 1 (to use CUMULATIVE incremental backups)
RECOVERY_WINDOW=35					#in days (at least one full business cycle + several days)
DBA_EMAIL="some.one@company.com"		#where to send notifications and errors
FIX_BEST_PRACTICES=1				#if 1, then will fix best practices automatically
BACKUP_PARALLELISM=2			#number of channels / parallelism

BACKUP_DEBUG=0						#one of: 0 or 1 (backup script debug)

#------------------------------------------------------------------

#ONDISK_LOCATION is for 9i databases only:
ONDISK_LOCATION="/u03/backup"		#if BACKUP_TYPE="DISK" then this is used as a backup location
									#  (only if FRA isn't available; ignored for FRA-enabled databases)


RETENTION="CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $RECOVERY_WINDOW DAYS"

if [ $USE_CATALOG = 1 ]; then
		cataloguid="catalog /@rmanc"	#If only "/@tns" format is used, assumes you're using Oracle Wallet.
else
		cataloguid=""					#RMAN catalog is not used.
fi

#set some global platform-dependent variables
ORATAB="/etc/oratab"
case `uname` in
	Linux)	HOSTNAME=`hostname -s`
			CVLIB='/opt/simpana/Base/libobk.so'			#Commvault library location
			;;
	AIX)	HOSTNAME=`hostname -s`
			CVLIB='/opt/simpana/Base64/libobk.a(shr.o)'
			;;
	HP-UX)	HOSTNAME=`hostname`
			CVLIB='/opt/simpana/Base64/libobk.sl'
			;;
	SunOS)	HOSTNAME=`hostname`
			CVLIB='/opt/simpana/Base64/libobk.so'
			ORATAB="/var/opt/oracle/oratab"
			;;
esac

SBT="DEVICE TYPE 'SBT_TAPE'"

#*** Choose appropriate backup type/location:
case $BACKUP_TYPE in
	DISK)	#1. on-disk backups:
		ALLOCATE_PARMS="DEVICE TYPE DISK"
		#   for on-disk you could also add     FORMAT '$DEST1/$FMT'   but this is not recommended - will not be FRA-managed
		#			e.g.   FORMAT       - use only for 9i databases that don't support FRA.
		;;
	Commvault)
		#2. Commvault
		#Don't set RETENTION POLICY if using Commvault (so Commvault can use its own Retention Policy)
				#   - or issue CONFIGURE RETENTION POLICY TO NONE as described in http://goo.gl/9dplVt
		RETENTION="CONFIGURE RETENTION POLICY TO NONE"

		CVINST="CvInstanceName=Instance001"
		ALLOCATE_PARMS="$SBT PARMS=\"SBT_LIBRARY=$CVLIB,BLKSIZE=262144,ENV=(CvClientName=$HOSTNAME,$CVINST)\""

		BACKUP_COMPRESS=0		#disable rman compression for Commvault as deduplication is more efficient
		;;
	TSM)	#3. Tivoli Storage Manager. This vendor was *not* yet tested enough, 
			#	but should work as is (adjust path to optfile and parameters it)
		ALLOCATE_PARMS="$SBT PARMS=\"ENV=(tdpo_optfile=/usr/tivoli/tsm/client/oracle/bin64/tdpo.opt)\""
		;;
esac

if [ $BACKUP_DEBUG = 1 ]; then
	set -x
	#if more verbose RMAN/Commvault tracing is desired:
	ALLOCATE_PARMS="$ALLOCATE_PARMS TRACE 2 DEBUG 2"
	#change DBA group email to a person's who is debugging backup scripts:
	DBA_EMAIL="some.one@company.com"
else
	#"normal" tracing/debugging parameters at RMAN channel level:
	ALLOCATE_PARMS="$ALLOCATE_PARMS TRACE 1"
fi


#Only for Dataguarded databases: We need to connect to primary db to archive current log.
#Oracle Wallet is used to store password for the databases. See end of main script for OW details.



#------------------------------------------------------------------
#
# Low-level / or rarely changed parameters on per-server basis:
#
#

db_backup_options="FILESPERSET 2"		#Don't make filesperset&maxpiecesize too high  -
arch_backup_options="FILESPERSET 4"		#  so multiplexing will work between parallel channels.
db_backup_incr_options="FILESPERSET 8"	#FILESPERSET etc in incremental database backups.
CHANNEL_SETLIMIT="MAXOPENFILES 8"		#SETLIMIT CHANNEL .. - will be used for each allocated channel.


RMAN_INIT="		SHOW ALL;
		SET ECHO ON;"
#BACKUP OPTIMIZATION ON is important e.g. to skip archived logs that were already backed up:
#CONFIGURE CONTROLFILE AUTOBACKUP OFF because we explicitly backup control and spfiles after each backup
RMAN_HEADER_SCRIPT="CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE CONTROLFILE AUTOBACKUP OFF;"
RMAN_TRAIL_SCRIPT=""

#OERR: RMAN-5021 this configuration cannot be changed for a BACKUP or STANDBY (Doc ID 291469.1)
#CONFIGURE RETENTION POLICY, CONFIGURE EXCLUDE, CONFIGURE ARCHIVELOG DELETION POLICY
#cannot be run on standby. So let's have a separate $RMAN_PRI_CONFIGURES that runs on primary only.
RMAN_PRI_CONFIGURES="$RETENTION;"


#------------------------------------------------------------------
FULL_BKP_DAY=6					#"DB"-backup scheduled mode: day of FULL backup (e.g. 6=Sat, 0=Sun)
FRA_WARN_THR=88					#FRA warning level, %; don't make it lower than 85% - see Doc ID 315098.1


BACKUP_FORMAT='$ONDISK_LOCATION/$db/rman_${tags}_%t_s%s_p%p.bkp'	#Will be used for BACKUP_TYPE=DISK *AND* pre-10g databases *only* (9i doesn't have FRA functionality)
								#This will be eval()ed so $db and $tags will get substituted with real values.

PATHS="/bin:/usr/bin:/usr/local/bin:$BASE_PATH"	#paths to utilities used by this script (oraenv,mailx,find,grep,egrep,sed,awk,tr,ps,wc)


if [ $CUMULATIVE = 1 ]; then
		CUMULATIVE="CUMULATIVE"		#So incremental backups will backup changes since last FULL backup.
else
		CUMULATIVE=""			#For CUMULATIVE=0 we will take changes since latest full *OR* another incremental backup.
fi

if [ $USE_CATALOG = 1 ]; then
	#We should connect to catalog as a separate RMAN command, not through command line.
	#So if catalog isn't available we still will have our regular backups, using control file instead.
	RMAN_INIT="CONNECT $cataloguid
		$RMAN_INIT"
fi

NICE=5							#How much to lower rman processes priority.
case `uname` in					#platform-specific renice/nice commands:
	Linux)	RENICE="renice +$NICE"	;;	#in Linux renice sets nice priority to absolute value,
	*)		RENICE="renice -n $NICE"	;;		#while in UNIX it is relative change (lowers priority)
esac
NICE="nice -n $NICE"

#------------------------------------------------------------------
#	Some environment variables:

#this will determine how RMAN will print date/time
export NLS_DATE_FORMAT="DAY DD/MON/YYYY HH24:MI:SS"

#UNIX95= is used for HP-UX (XPG4) only, but safe to leave as-is for other platforms
#HP-UX: /usr/dt/bin/dtksh is closest ksh93 equivalent
export UNIX95=1									



#------------------------------------------------------------------
