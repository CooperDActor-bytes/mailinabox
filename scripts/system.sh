# Turn on basic services:
#   ntp: keeps the system time correct
#   fail2ban: scans log files for repeated failed login attempts and blocks the remote IP at the firewall

apt-get install -q -y ntp fail2ban

# Turn on the firewall. First allow incoming SSH, then turn on the firewall. Additional open
# ports will be set up in the scripts that set up those services.
if [ -z "$DISABLE_FIREWALL" ]; then
	ufw allow ssh;
	ufw --force enable;
fi

