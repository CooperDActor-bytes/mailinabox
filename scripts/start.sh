# This is the entry point for configuring the system.
#####################################################

# Check system setup.

# Gather information from the user about the hostname and public IP
# address of this host.
if [ -z "$PUBLIC_HOSTNAME" ]; then
	echo
	echo "Enter the hostname you want to assign to this machine."
	echo "We've guessed a value. Just backspace it if it's wrong."
	echo "Josh uses box.occams.info as his hostname. Yours should"
	echo "be similar."
	echo
	read -e -i "`hostname`" -p "Hostname: " PUBLIC_HOSTNAME
fi

if [ -z "$PUBLIC_IP" ]; then
	echo
	echo "Enter the public IP address of this machine, as given to"
	echo "you by your ISP. We've guessed a value, but just backspace"
	echo "it if it's wrong."
	echo
	read -e -i "`hostname -i`" -p "Public IP: " PUBLIC_IP
fi

# Create the user named "userconfig-data" and store all persistent user
# data (mailboxes, etc.) in that user's home directory.
if [ -z "$STORAGE_ROOT" ]; then
	STORAGE_USER=user-data
	if [ ! -d /home/$STORAGE_USER ]; then useradd -m $STORAGE_USER; fi
	STORAGE_ROOT=/home/$STORAGE_USER
	mkdir -p $STORAGE_ROOT
fi

# Save the global options in /etc/mailinabox.conf so that standalone
# tools know where to look for data.
cat > /etc/mailinabox.conf << EOF;
STORAGE_ROOT=$STORAGE_ROOT
PUBLIC_HOSTNAME=$PUBLIC_HOSTNAME
PUBLIC_IP=$PUBLIC_IP
EOF

# Start service configuration.
. scripts/system.sh
. scripts/dns.sh
. scripts/mail.sh
. scripts/dkim.sh
. scripts/spamassassin.sh
. scripts/dns_update.sh

if [ -z `tools/mail.py user` ]; then
	# The outut of "tools/mail.py user" is a list of mail users. If there
	# are none configured, ask the user to configure one.
	echo
	echo "Let's create your first mail user."
	read -e -i "user@`hostname`" -p "Email Address: " EMAIL_ADDR
	tools/mail.py user add $EMAIL_ADDR # will ask for password
	tools/mail.py alias add hostmaster@$PUBLIC_HOSTNAME $EMAIL_ADDR
fi

