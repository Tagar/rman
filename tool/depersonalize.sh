
# This script changes all of the emails in the .vars script to 
#  to some.one@company.com before submitting to public GitHub.
# Also, it resets BACKUP_TYPE to a more common DISK type.

perl -i.bak -pe "s/EMAIL=\".+?\"/EMAIL=\"some.one\@company.com\"/g; s/BACKUP_TYPE=\".+?\"/BACKUP_TYPE=\"DISK\"/ " ../rman_backup_vars.sh

