#!/bin/bash
# HTTP: Turn on a web server serving static files
#################################################

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars

# Some Ubuntu images start off with Apache. Remove it since we
# will use nginx. Use autoremove to remove any Apache depenencies.
if [ -f /usr/sbin/apache2 ]; then
	echo Removing apache...
	hide_output apt-get -y purge apache2 apache2-*
	hide_output apt-get -y --purge autoremove
fi

# Ubuntu 14.04 comes with nginx 1.4.6, but we want 1.6.x to have SPDY support
# which is the more modern best practice. We'll get nginx from the nginx PPA.
# An update from stock nginx to the nginx ppa causes trouble, so we'll purge
# first.
if nginx -v 2>&1 | grep 1.4; then
	apt-get purge -y nginx
fi

# Then add the PPA. Test first so we don't have to run apt-get update if the
# PPA was already present.
if [ ! -f /etc/apt/sources.list.d/nginx-stable-trusty.list ]; then
	hide_output add-apt-repository -y ppa:nginx/stable
	hide_output apt-get update
fi

# Install nginx and a PHP FastCGI daemon.

apt_install nginx php5-fpm

# Turn off nginx's default website.

rm -f /etc/nginx/sites-enabled/default

# Copy in a nginx configuration file for common and best-practices
# SSL settings from @konklone. Replace STORAGE_ROOT so it can find
# the DH params.
sed "s#STORAGE_ROOT#$STORAGE_ROOT#" \
	conf/nginx-ssl.conf > /etc/nginx/nginx-ssl.conf

# Fix some nginx defaults.
# The server_names_hash_bucket_size seems to prevent long domain names?
tools/editconf.py /etc/nginx/nginx.conf -s \
	server_names_hash_bucket_size="64;"

# Bump up PHP's max_children to support more concurrent connections
tools/editconf.py /etc/php5/fpm/pool.d/www.conf -c ';' \
	pm.max_children=8

# Other nginx settings will be configured by the management service
# since it depends on what domains we're serving, which we don't know
# until mail accounts have been created.

# Create the iOS/OS X Mobile Configuration file which is exposed via the
# nginx configuration at /mailinabox-mobileconfig.
mkdir -p /var/lib/mailinabox
chmod a+rx /var/lib/mailinabox
cat conf/ios-profile.xml \
	| sed "s/PRIMARY_HOSTNAME/$PRIMARY_HOSTNAME/" \
	| sed "s/UUID1/$(cat /proc/sys/kernel/random/uuid)/" \
	| sed "s/UUID2/$(cat /proc/sys/kernel/random/uuid)/" \
	| sed "s/UUID3/$(cat /proc/sys/kernel/random/uuid)/" \
	| sed "s/UUID4/$(cat /proc/sys/kernel/random/uuid)/" \
	 > /var/lib/mailinabox/mobileconfig.xml
chmod a+r /var/lib/mailinabox/mobileconfig.xml

# make a default homepage
if [ -d $STORAGE_ROOT/www/static ]; then mv $STORAGE_ROOT/www/static $STORAGE_ROOT/www/default; fi # migration #NODOC
mkdir -p $STORAGE_ROOT/www/default
if [ ! -f $STORAGE_ROOT/www/default/index.html ]; then
	cp conf/www_default.html $STORAGE_ROOT/www/default/index.html
fi
chown -R $STORAGE_USER $STORAGE_ROOT/www

# We previously installed a custom init script to start the PHP FastCGI daemon. #NODOC
# Remove it now that we're using php5-fpm. #NODOC
if [ -L /etc/init.d/php-fastcgi ]; then
	echo "Removing /etc/init.d/php-fastcgi, php5-cgi..." #NODOC
	rm -f /etc/init.d/php-fastcgi #NODOC
	hide_output update-rc.d php-fastcgi remove #NODOC
	apt-get -y purge php5-cgi #NODOC
fi

# Remove obsoleted scripts. #NODOC
# exchange-autodiscover is now handled by Z-Push. #NODOC
for f in webfinger exchange-autodiscover; do #NODOC
	rm -f /usr/local/bin/mailinabox-$f.php #NODOC
done #NODOC

# Start services.
restart_service nginx
restart_service php5-fpm

# Open ports.
ufw_allow http
ufw_allow https

