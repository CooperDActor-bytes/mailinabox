source /etc/mailinabox.conf
source setup/functions.sh

# Add additional packages
apt_install pflogsumm rkhunter chkrootkit

# Cleanup old spam and trash email
hide_output install -m 755 conf/cron/miab_clean_mail /etc/cron.weekly/

# Reduce logs by not logging mail output in syslog
sed -i "s/\*\.\*;auth,authpriv.none.*\-\/var\/log\/syslog/\*\.\*;mail,auth,authpriv.none    \-\/var\/log\/syslog/g" /etc/rsyslog.d/50-default.conf

# Reduce logs by only logging ufw in ufw.log
sed -i "s/#\& stop/\& stop/g" /etc/rsyslog.d/20-ufw.conf

restart_service rsyslog

# decrease time journal is stored
tools/editconf.py /etc/systemd/journald.conf MaxRetentionSec=2month
tools/editconf.py /etc/systemd/journald.conf MaxFileSec=1week

hide_output systemctl restart systemd-journald.service

# Create forward for root emails
cat > /root/.forward << EOF;
administrator@$PRIMARY_HOSTNAME
EOF

# Install fake mail script
if [ ! -f /usr/local/bin/mail ]; then
        hide_output install -m 755 tools/fake_mail /usr/local/bin
        mv -f /usr/local/bin/fake_mail /usr/local/bin/mail
fi

tools/editconf.py /etc/rkhunter.conf \
        UPDATE_MIRRORS=1 \
        MIRRORS_MODE=0 \
        WEB_CMD='""' \
        MAIL-ON-WARNING=root \
        ALLOWHIDDENDIR=/etc/.java

tools/editconf.py /etc/default/rkhunter \
        CRON_DAILY_RUN='"true"' \
        CRON_DB_UPDATE='"true"' \
        APT_AUTOGEN='"true"'

tools/editconf.py /etc/chkrootkit.conf \
        RUN_DAILY='"true"'

# Should be last
rkhunter --propupd

