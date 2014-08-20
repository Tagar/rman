
Shell script to run scheduled Oracle RMAN backup scripts for various usage scenarios.

Using Data Guard and want to backups to run normally only on Standby database?
What if DG apply process is behind? Oh, now you want to run backups from Primary database?
Or maybe you're having a RAC database and want to easily schedule non-competing backups 
that would run even if you loose any number of cluster nodes?
Maybe you're using some backups solutions like Commvault or Tivoli, or just dump backups 
to FRA?

This script will help to address above scenarios and combinations of those.
It will notify you of daily backups results, or any problems that may happen.

Setup is as easy as download files from this repository into your servers; 
add a few entries to crontab 
(e.g. one to call rman_backup.sh for database backups, another for archived logs, 
plus crosscheck weekly or any other schedule that works for you better). 
Also, review rman_backup_vars.sh script if there are any changes are required for your environment.

I'd be happy to receive feedback.
Found a bug? Please submit it here - https://github.com/Tagar/rman/issues 
Also, feel free to contribute your changes to this repository.
