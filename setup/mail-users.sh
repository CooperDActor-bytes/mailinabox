#!/bin/bash
#
# User Authentication and Destination Validation
# ----------------------------------------------
#
# This script configures user authentication for Dovecot
# and Postfix (which relies on Dovecot) and destination
# validation by quering an Sqlite3 database of mail users. 

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars

# ### User and Alias Database

# The database of mail users (i.e. authenticated users, who have mailboxes)
# and aliases (forwarders).

db_path=$STORAGE_ROOT/mail/users.sqlite

# Create an empty database if it doesn't yet exist.
if [ ! -f $db_path ]; then
	echo Creating new user database: $db_path;
	echo "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT NOT NULL UNIQUE, password TEXT NOT NULL, extra, privileges TEXT NOT NULL DEFAULT '');" | sqlite3 $db_path;
	echo "CREATE TABLE aliases (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL UNIQUE, destination TEXT NOT NULL);" | sqlite3 $db_path;
fi

# ### User Authentication

# Have Dovecot query our database, and not system users, for authentication.
sed -i "s/#*\(\!include auth-system.conf.ext\)/#\1/"  /etc/dovecot/conf.d/10-auth.conf
sed -i "s/#\(\!include auth-sql.conf.ext\)/\1/"  /etc/dovecot/conf.d/10-auth.conf

# Specify how the database is to be queried for user authentication (passdb)
# and where user mailboxes are stored (userdb).
cat > /etc/dovecot/conf.d/auth-sql.conf.ext << EOF;
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
  driver = static
  args = uid=mail gid=mail home=$STORAGE_ROOT/mail/mailboxes/%d/%n
}
EOF

# Configure the SQL to query for a user's password.
cat > /etc/dovecot/dovecot-sql.conf.ext << EOF;
driver = sqlite
connect = $db_path
default_pass_scheme = SHA512-CRYPT
password_query = SELECT email as user, password FROM users WHERE email='%u';
EOF
chmod 0600 /etc/dovecot/dovecot-sql.conf.ext # per Dovecot instructions

# Have Dovecot provide an authorization service that Postfix can access & use.
# Drew Crawford sets the auth-worker process to run as the mail user, but we don't care if it runs as root.
cat > /etc/dovecot/conf.d/99-local-auth.conf << EOF;
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}
EOF

# And have Postfix use that service.
tools/editconf.py /etc/postfix/main.cf \
	smtpd_sasl_type=dovecot \
	smtpd_sasl_path=private/auth \
	smtpd_sasl_auth_enable=yes

# ### Destination Validation

# Use a Sqlite3 database to check whether a destination email address exists,
# and to perform any email alias rewrites in Postfix.
tools/editconf.py /etc/postfix/main.cf \
	virtual_mailbox_domains=sqlite:/etc/postfix/virtual-mailbox-domains.cf \
	virtual_mailbox_maps=sqlite:/etc/postfix/virtual-mailbox-maps.cf \
	virtual_alias_maps=sqlite:/etc/postfix/virtual-alias-maps.cf, \
                    sqlite:/etc/postfix/virtual-self-alias-maps.cf \
	local_recipient_maps=\$virtual_mailbox_maps

# SQL statement to check if we handle mail for a domain, either for users or aliases.
cat > /etc/postfix/virtual-mailbox-domains.cf << EOF;
dbpath=$db_path
query = SELECT 1 FROM users WHERE email LIKE '%%@%s' UNION SELECT 1 FROM aliases WHERE source LIKE '%%@%s'
EOF

# SQL statement to check if we handle mail for a user.
cat > /etc/postfix/virtual-mailbox-maps.cf << EOF;
dbpath=$db_path
query = SELECT 1 FROM users WHERE email='%s'
EOF

# SQL statement to rewrite an email address if an alias is present.
cat > /etc/postfix/virtual-alias-maps.cf << EOF;
dbpath=$db_path
query = SELECT destination FROM aliases WHERE source='%s'
EOF

# SQL statement to implicitly define an alias for each user so that existing users won't be caught by catchall aliases.
cat > /etc/postfix/virtual-self-alias-maps.cf << EOF;
dbpath=$db_path
query = SELECT email FROM users WHERE email='%s'
EOF

# Restart Services
##################

restart_service postfix
restart_service dovecot


