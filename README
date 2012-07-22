Twitter-backed IRC bot
======================
Originally a demonstration of best-practices twitter API use (http://hatsaregay.com/?p=1), this project has been updated to have a working use-case (namely, an IRC bot and twitter-polling backend).

The bot (bot.pm) will connect to the supplied IRC server and channels and announce in the primary channel whenever a twitter user updates their status (see config.yaml). A separate script, updatedb.pm periodically polls for updates and saves them to an sqlite3 database, which the bot checks to determine whether any new statuses have arrived. updatedb.pm is run automatically by bot.pm, or can be run on it's own or as a cronjob if bot.pm is run with the -d argument.

Usage
-----
- Rename config|bot.yaml.template to config|bot.yaml. 

*config.yaml* contains Twitter-related settings (your user-keys and a list of usernames to poll for updates)
*bot.yaml* contains IRC related settings, including server details, password and channels.

- Create database: `sqlite3 twitter.db < schema.sql`
- Run the bot! `./bot.pm`

### Additional Arguments
-d: run bot in "dumb" mode (will not check for updates to user statuses). This is useful if running multiple bots on multiple servers, or if you are running updatedb.pm externally.
-s *<settings_name>*: supply a different bot.yaml file with alternate servers and channels to join. File must be called bot.*<settings_name>*.yaml
