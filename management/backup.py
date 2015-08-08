#!/usr/bin/python3

# This script performs a backup of all user data:
# 1) System services are stopped while a copy of user data is made.
# 2) An incremental encrypted backup is made using duplicity into the
#    directory STORAGE_ROOT/backup/encrypted. The password used for
#    encryption is stored in backup/secret_key.txt.
# 3) The stopped services are restarted.
# 5) STORAGE_ROOT/backup/after-backup is executd if it exists.

import os, os.path, shutil, glob, re, datetime
import dateutil.parser, dateutil.relativedelta, dateutil.tz
import rtyaml
import logging

from utils import exclusive_process, load_environment, shell, wait_for_service

# Root folder
backup_root = os.path.join(load_environment()["STORAGE_ROOT"], 'backup')

# Setup logging
log_path = os.path.join(backup_root, 'backup.log')
logging.basicConfig(filename=log_path, format='%(levelname)s at %(asctime)s: %(message)s')

# Default settings
# min_age_in_days is the minimum amount of days a backup will be kept before
# it is eligble to be removed. Backups might be kept much longer if there's no
# new full backup yet.
default_config = {
	"min_age_in_days": 3,
	"target": "file://" + os.path.join(backup_root, 'encrypted')
}

def backup_status(env):
	# What is the current status of backups?
	# Query duplicity to get a list of all backups.
	# Use the number of volumes to estimate the size.
	config = get_backup_config()
	now = datetime.datetime.now(dateutil.tz.tzlocal())

	backups = { }
	backup_dir = os.path.join(backup_root, 'encrypted')
	backup_cache_dir = os.path.join(backup_root, 'cache')

	def reldate(date, ref, clip):
		if ref < date: return clip
		rd = dateutil.relativedelta.relativedelta(ref, date)
		if rd.months > 1: return "%d months, %d days" % (rd.months, rd.days)
		if rd.months == 1: return "%d month, %d days" % (rd.months, rd.days)
		if rd.days >= 7: return "%d days" % rd.days
		if rd.days > 1: return "%d days, %d hours" % (rd.days, rd.hours)
		if rd.days == 1: return "%d day, %d hours" % (rd.days, rd.hours)
		return "%d hours, %d minutes" % (rd.hours, rd.minutes)

	def parse_line(line):
		keys = line.strip().split()
		date = dateutil.parser.parse(keys[1])
		return {
			"date": keys[1],
			"date_str": date.strftime("%x %X"),
			"date_delta": reldate(date, now, "the future?"),
			"full": keys[0] == "full",
			"size": int(keys[2]) * 250 * 1000000,
		}

	# Get duplicity collection status
	collection_status = shell('check_output', [
		"/usr/bin/duplicity",
		"collection-status",
		"--archive-dir", backup_cache_dir,
		"--log-file", os.path.join(backup_root, "duplicity_status"),
		"--gpg-options", "--cipher-algo=AES256",
		"--log-fd", "1",
		config["target"],
		],
		get_env())

	# Split multi line string into list
	collection_status = collection_status.split('\n')

	# Parse backup data from status file
	for line in collection_status:
		if line.startswith(" full") or line.startswith(" inc"):
			backup = parse_line(line)
			backups[backup["date"]] = backup

	# Ensure the rows are sorted reverse chronologically.
	# This is relied on by should_force_full() and the next step.
	backups = sorted(backups.values(), key = lambda b : b["date"], reverse=True)

	# Get the average size of incremental backups and the size of the
	# most recent full backup.
	incremental_count = 0
	incremental_size = 0
	first_full_size = None
	for bak in backups:
		if bak["full"]:
			first_full_size = bak["size"]
			break
		incremental_count += 1
		incremental_size += bak["size"]

	# Predict how many more increments until the next full backup,
	# and add to that the time we hold onto backups, to predict
	# how long the most recent full backup+increments will be held
	# onto. Round up since the backup occurs on the night following
	# when the threshold is met.
	deleted_in = None
	if incremental_count > 0 and first_full_size is not None:
		deleted_in = "approx. %d days" % round(config["min_age_in_days"] + (.5 * first_full_size - incremental_size) / (incremental_size/incremental_count) + .5)

	# When will a backup be deleted?
	saw_full = False
	days_ago = now - datetime.timedelta(days=config["min_age_in_days"])
	for bak in backups:
		if deleted_in:
			# Subsequent backups are deleted when the most recent increment
			# in the chain would be deleted.
			bak["deleted_in"] = deleted_in
		if bak["full"]:
			# Reset when we get to a full backup. A new chain start next.
			saw_full = True
			deleted_in = None
		elif saw_full and not deleted_in:
			# Mark deleted_in only on the first increment after a full backup.
			deleted_in = reldate(days_ago, dateutil.parser.parse(bak["date"]), "on next daily backup")
			bak["deleted_in"] = deleted_in

	return {
		"directory": backup_dir,
		"encpwfile": os.path.join(backup_root, 'secret_key.txt'),
		"tz": now.tzname(),
		"backups": backups,
	}

def should_force_full(env):
	# Force a full backup when the total size of the increments
	# since the last full backup is greater than half the size
	# of that full backup.
	inc_size = 0
	for bak in backup_status(env)["backups"]:
		if not bak["full"]:
			# Scan through the incremental backups cumulating
			# size...
			inc_size += bak["size"]
		else:
			# ...until we reach the most recent full backup.
			# Return if we should to a full backup.
			return inc_size > .5*bak["size"]
	else:
		# If we got here there are no (full) backups, so make one.
		# (I love for/else blocks. Here it's just to show off.)
		return True

def get_passphrase():
	# Get the encryption passphrase. secret_key.txt is 2048 random
	# bits base64-encoded and with line breaks every 65 characters.
	# gpg will only take the first line of text, so sanity check that
	# that line is long enough to be a reasonable passphrase. It
	# only needs to be 43 base64-characters to match AES256's key
	# length of 32 bytes.
	with open(os.path.join(backup_root, 'secret_key.txt')) as f:
		passphrase = f.readline().strip()
	if len(passphrase) < 43: raise Exception("secret_key.txt's first line is too short!")
	
	return passphrase

def get_env():
	config = get_backup_config()
	
	env = { "PASSPHRASE" : get_passphrase() }
	
	if get_target_type(config) == 's3':
		env["AWS_ACCESS_KEY_ID"] = config["target_user"]
		env["AWS_SECRET_ACCESS_KEY"] = config["target_pass"]
	
	return env
	
def get_target_type(config):
	protocol = config["target"].split(":")[0]
	return protocol
	
def perform_backup(full_backup):
	env = load_environment()

	exclusive_process("backup")
	config = get_backup_config()
	backup_cache_dir = os.path.join(backup_root, 'cache')
	backup_dir = os.path.join(backup_root, 'encrypted')

	# In an older version of this script, duplicity was called
	# such that it did not encrypt the backups it created (in
	# backup/duplicity), and instead openssl was called separately
	# after each backup run, creating AES256 encrypted copies of
	# each file created by duplicity in backup/encrypted.
	#
	# We detect the transition by the presence of backup/duplicity
	# and handle it by 'dupliception': we move all the old *un*encrypted
	# duplicity files up out of the backup/duplicity directory (as
	# backup/ is excluded from duplicity runs) in order that it is
	# included in the next run, and we delete backup/encrypted (which
	# duplicity will output files directly to, post-transition).
	old_backup_dir = os.path.join(backup_root, 'duplicity')
	migrated_unencrypted_backup_dir = os.path.join(env["STORAGE_ROOT"], "migrated_unencrypted_backup")
	if os.path.isdir(old_backup_dir):
		# Move the old unencrypted files to a new location outside of
		# the backup root so they get included in the next (new) backup.
		# Then we'll delete them. Also so that they do not get in the
		# way of duplicity doing a full backup on the first run after
		# we take care of this.
		shutil.move(old_backup_dir, migrated_unencrypted_backup_dir)

		# The backup_dir (backup/encrypted) now has a new purpose.
		# Clear it out.
		shutil.rmtree(backup_dir)

	# On the first run, always do a full backup. Incremental
	# will fail. Otherwise do a full backup when the size of
	# the increments since the most recent full backup are
	# large.
	full_backup = full_backup or should_force_full(env)

	# Stop services.
	shell('check_call', ["/usr/sbin/service", "dovecot", "stop"])
	shell('check_call', ["/usr/sbin/service", "postfix", "stop"])

	# Run a backup of STORAGE_ROOT (but excluding the backups themselves!).
	# --allow-source-mismatch is needed in case the box's hostname is changed
	# after the first backup. See #396.
	try:
		shell('check_call', [
			"/usr/bin/duplicity",
			"full" if full_backup else "incr",
			"--archive-dir", backup_cache_dir,
			"--asynchronous-upload",
			"--exclude", backup_root,
			"--volsize", "250",
			"--gpg-options", "--cipher-algo=AES256",
			env["STORAGE_ROOT"],
			config["target"],
			"--allow-source-mismatch"
			],
			get_env())
		logging.info("Backup successful")
	except Exception as e:
		logging.warn("Backup failed: {0}".format(e))
	finally:
		# Start services again.
		shell('check_call', ["/usr/sbin/service", "dovecot", "start"])
		shell('check_call', ["/usr/sbin/service", "postfix", "start"])

	# Once the migrated backup is included in a new backup, it can be deleted.
	if os.path.isdir(migrated_unencrypted_backup_dir):
		shutil.rmtree(migrated_unencrypted_backup_dir)

	# Remove old backups. This deletes all backup data no longer needed
	# from more than 3 days ago.
	try:
		shell('check_call', [
			"/usr/bin/duplicity",
			"remove-older-than",
			"%dD" % config["min_age_in_days"],
			"--archive-dir", backup_cache_dir,
			"--force",
			config["target"]
			],
			get_env())
	except Exception as e:
		logging.warn("Removal of old backups failed: {0}".format(e))

	# From duplicity's manual:
	# "This should only be necessary after a duplicity session fails or is
	# aborted prematurely."
	# That may be unlikely here but we may as well ensure we tidy up if
	# that does happen - it might just have been a poorly timed reboot.
	try:
		shell('check_call', [
			"/usr/bin/duplicity",
			"cleanup",
			"--archive-dir", backup_cache_dir,
			"--force",
			config["target"]
			],
			get_env())
	except Exception as e:
		logging.warn("Cleanup of backups failed: {0}".format(e))

	# Change ownership of backups to the user-data user, so that the after-bcakup
	# script can access them.
	if get_target_type(config) == 'file':
		shell('check_call', ["/bin/chown", "-R", env["STORAGE_USER"], backup_dir])

	# Execute a post-backup script that does the copying to a remote server.
	# Run as the STORAGE_USER user, not as root. Pass our settings in
	# environment variables so the script has access to STORAGE_ROOT.
	post_script = os.path.join(backup_root, 'after-backup')
	if os.path.exists(post_script):
		shell('check_call',
			['su', env['STORAGE_USER'], '-c', post_script, config["target"]],
			env=get_env())

	# Our nightly cron job executes system status checks immediately after this
	# backup. Since it checks that dovecot and postfix are running, block for a
	# bit (maximum of 10 seconds each) to give each a chance to finish restarting
	# before the status checks might catch them down. See #381.
	wait_for_service(25, True, env, 10)
	wait_for_service(993, True, env, 10)

def run_duplicity_verification():
	env = load_environment()
	config = get_backup_config()
	backup_cache_dir = os.path.join(backup_root, 'cache')

	shell('check_call', [
		"/usr/bin/duplicity",
		"--verbosity", "info",
		"verify",
		"--compare-data",
		"--archive-dir", backup_cache_dir,
		"--exclude", backup_root,
		config["target"],
		env["STORAGE_ROOT"],
	], get_env())


def backup_set_custom(target, target_user, target_pass, min_age):
	config = get_backup_config()
	
	# min_age must be an int
	if isinstance(min_age, str):
		min_age = int(min_age)

	config["target"] = target
	config["target_user"] = target_user
	config["target_pass"] = target_pass
	config["min_age_in_days"] = min_age
	
	write_backup_config(config)

	return "Updated backup config"
	
def get_backup_config():
	try:
		config = rtyaml.load(open(os.path.join(backup_root, 'custom.yaml')))
		if not isinstance(config, dict): raise ValueError() # caught below
	except:
		return default_config

	merged_config = default_config.copy()
	merged_config.update(config)

	return config
	
def get_backup_log():
	try:
		fileHandle = open(log_path, 'r')
		log = fileHandle.read()
		fileHandle.close()
	except:
		log = ""

	return log

def write_backup_config(newconfig):
	with open(os.path.join(backup_root, 'custom.yaml'), "w") as f:
		f.write(rtyaml.dump(newconfig))

if __name__ == "__main__":
	import sys
	if sys.argv[-1] == "--verify":
		# Run duplicity's verification command to check a) the backup files
		# are readable, and b) report if they are up to date.
		run_duplicity_verification()

	else:
		# Perform a backup. Add --full to force a full backup rather than
		# possibly performing an incremental backup.
		full_backup = "--full" in sys.argv
		perform_backup(full_backup)
