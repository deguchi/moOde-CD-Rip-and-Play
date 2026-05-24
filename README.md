# moOde-CD-Rip-and-Play

> **This is a fork of [TheMetalHead/moOde-CD-Rip-and-Play](https://github.com/TheMetalHead/moOde-CD-Rip-and-Play), updated for moOde 10.2.0 compatibility.**

A companion program for the moOde audio player (http://moodeaudio.org/) to rip and tag CDs and play them. Either as 320kbps mp3 files, flac and/or mpc.

This is not a program for an alternative user interface to moOde.

It allows a user to play their CDs without using the moOde interface. The volume being adjusted using an attached rotary encoder. CDs that have already been ripped can be batch queued for playing. It sort of emulates the old fashioned juke box except that instead of feeding in money, you feed in the discs.

Is copying CDs legal? If you are not sure what the position is for the country you live in, please check your local copyright law to make sure that you are on the right side of the law before using the software featured here.

# What's changed in this fork (v2.0)

The original project was built for moOde v6.5.0 on Raspberry Pi 3. Since then, moOde has undergone significant changes. This fork addresses the following compatibility issues:

- **Dynamic user detection**: The default `pi` user was removed in moOde 8.3+. The user is now detected automatically via `SUDO_USER`, `LOGNAME`, or `getent`.
- **moOde 10.x detection**: moOde detection now checks for `playback.php` in addition to the legacy `moode.php`.
- **Storage path**: Default rip destination changed from `~/Music-CD/` to `/mnt/OSDISK/` (configurable), the standard music storage location on moOde 10.
- **Debian Trixie compatibility**: Command paths updated from `/bin/*` to `/usr/bin/*` (on Debian Trixie, `/bin` is a symlink to `/usr/bin`).
- **Volume control fallback**: Falls back to `mpc volume` when `rotvol.sh` is not available on newer moOde versions.
- **WebUI library update**: After ripping, the moOde WebUI library update is triggered automatically via the `music-library.php` API, so new albums and cover art appear without manual intervention.
- **Library cache handling**: The `libcache.json` truncation is guarded with a file existence check, as this file no longer exists on moOde 10.
- **Service file templates**: Systemd service files use `.service.in` templates to prevent `git pull` from overwriting configured paths.

### Tested on

| Component | Version |
|-----------|---------|
| moOde | 10.2.0 |
| Raspberry Pi OS | Trixie (Debian 13) |
| Raspberry Pi | 3 |

Raspberry Pi 4 and 5 should also work but have not been tested.

# Requirements

- moOde audio player v10.x (tested on v10.2.0)
- Raspberry Pi 3 / 4 / 5
- Raspberry Pi OS Trixie (Debian 13)
- An external USB CD drive

# Download

  Download the files using git

	git clone https://github.com/deguchi/moOde-CD-Rip-and-Play.git
	cd moOde-CD-Rip-and-Play

# Configuration

The configuration files have the format VARIABLE=value
Except when "value" needs to be quoted or otherwise interpreted, if other variables within "value" are to be expanded upon reading the configuration file, then double quotes should be used.  If they are only supposed to be expanded upon use (for example OUTPUTFORMAT) then single quotes must be used.

All shell escaping/quoting rules apply.



Edit the configuration file as required: cd-rip-and-or-play.conf

The music files can reside in either:
MUSIC_HOME_PATH/RIPPED_MUSIC_DIR/MUSIC_SUB_DIR
or
MUSIC_HOME_PATH/RIPPED_MUSIC_DIR

By default, ripped files are stored under `/mnt/OSDISK/` so they appear in the moOde library alongside your other music. The following variables can be adjusted:

MUSIC_HOME_PATH : Full path to the music files (default: auto-detected user home, or `/mnt` for OSDISK). Do not add any trailing slashes.

RIPPED_MUSIC_DIR : Directory containing the music files (default: `OSDISK`). Do not add any leading/trailing slashes.

RIPPED_MUSIC_OWNER : File ownership (default: auto-detected user). WARNING: The owner existence is not checked.

LIBRARY_TAG : The name that is displayed in the moOde library menu (default: `OSDISK`). Do not add any leading/trailing slashes.

MUSIC_MNT_SOURCE : This should be OSDISK, CD, NAS, USB, NVME or SATA. It is the name used in the `/mnt` directory (default: `OSDISK`). Do not add any leading/trailing slashes.

MUSIC_SUB_DIR : Optional. Can be used to differentiate between your music files and ripped music files. Must either be empty ("") or have no leading/trailing slashes.

DEFAULT_VOLUME=10 : The default volume that moOde will play the CD at.

Set the log level as required by uncommenting one of the following: #_LOG_LEVEL=${LOG_LEVEL_NOLOG} or #_LOG_LEVEL=${LOG_LEVEL_LOG} or #_LOG_LEVEL=${LOG_LEVEL_DEBUG}

All other configuration options can be left unchanged.

The configuration file: abcde.conf

  Each track is, by default, placed in a separate file named after the track in a subdirectory named after the artist under the current directory. This can be modified using the OUTPUTFORMAT and VAOUTPUTFORMAT variables in the abcde.conf file. Each file is given an extension identifying its compression format, eg '.mp3', '.flac' etc.

# Installation

There is a bash script called 'Install-cd-rip.sh' that checks for and installs the required programs, generates the systemd service files from templates, and creates the required links for moOde.

	chmod 544 *.sh
	sudo ./Install-cd-rip.sh

The required programs are:

  abcde
  cd-discid
  eject
  flock
  touch
  truncate
  mpc
  mpd
  cdparanoia
  lame
  flac
  mpcenc
  glyrc
  eyeD3

A bash script called 'Remove-cd-rip.sh' can be used to remove installed files and the links for moOde.

The downloaded 'moOde-CD-Rip-and-Play' files will be left untouched. These can be manually deleted. The ripped music will be left untouched, but the hidden disc id directory '.Music CDs Ripped' will be removed.

# Updating

  Pull the latest changes and re-run the installer:

	cd ~/moOde-CD-Rip-and-Play
	git pull
	sudo ./Install-cd-rip.sh

  Your `cd-rip-and-or-play.conf` settings will be preserved. The systemd service files are regenerated from templates on each install, so `git pull` will not overwrite your configured paths.

# Usage

  Insert the CD into the drive. The CD will be checked to see if it has been previously ripped. If not, the ripping process will take about 12 minutes. After this, the CD will be ejected and moOde will play the ripped files. If the CD has been previously ripped, it will be ejected and moOde will play the ripped files. More CDs can be inserted for batch queueing.

  Cover art is automatically fetched from MusicBrainz/CoverArtArchive and embedded in each track.

# Default cd cover

	default-cd-cover.jpg comes from https://commons.wikimedia.org/wiki/File:CD_icon_test.svg under the license of https://commons.wikimedia.org/wiki/Commons:GNU_Free_Documentation_License,_version_1.2

	No changes were made to the cover.

# License

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

Original work (c) 2020 TheMetalHead.
