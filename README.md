# TyR Media Server

This is a media server for media library management. It uses PIA WireGuard vpn provider, if you have a different VPN provider or need to use OpenVPN - you might need to tweak the scripts.

## How to start

1. Configure mandatory variables in `.env` file:

- `MASTER_FOLDER` - the folder where everything will be stored, you can use symlinks inside it to forward different things into different places
- `HOSTNAME` - list of allowed hostnames for Homepage service: for example `localhost,ivanpc.local`

> If you're using symlinks, make sure folders `$MASTER_FOLDER/downloads` and `$MASTER_FOLDER/media` point to the same physical volume, otherwise hardlinking downloaded media from downloads to media folder won't work and you'll end up with coplete copies of files.

All the other variables are optional, you can use them for fine-tuning your setup.

2. Start the server using `./start.sh` command, enter your PIA credentials - it will generate `.secrets` file in current folder and wireguard configuration. They will be used for VPN connection.

3. At this point, you can test that VPN is working: open browser, set up HTTP proxy on `localhost:PROXY_PORT` (8888 by default), and check your IP address.

## How to update / upgrade

Just run `./update.sh`.

## How to configure

### Fix media folders permissions. If they were created by docker running under root, they will be root-owned, but the services are user-owned, so we need to run:

`sudo chown -R user:user ${MEDIA_FOLDER}`, where `user` - your username, `${MEDIA_FOLDER}` - path taken from `.env` file.

> Consider doing the same for any sub-folders for dowloads: `downloads/custom-media` etc.

### Set up qBitTorrent

- Disable localhost authentication
- Disable authentication for `172.16.0.0/12` address - Docker IP ranges for local addresses
- Check port, restart EVERYTHING, check port again - should be changed to the one forwarded by PIA

- Behavior
  - Show external IP in status bar

- Downloads
  - Excluded file names: `*.lnk`

- Connection
  - Uncheck all connections limits

- Speed
  - Alternative Rate Limits: 1000 upload, 3000 download

- BitTorrent
  - Uncheck Torrent Queueing
  - Seeding limits: when ratio reaches 2, seeding time reaches 10080 minutes (7 days), inactive seeding time reaches 10080 minutes (7 days) - STOP torrent (not delete)

- Advanced
  - RAM limit: 12288 (12 Gb)
  - Recheck torrents on completion (better integrity)

### Set up: Sonarr, Radarr

- Authentication method: basic (admin, qwerty)
- Authentication required: Disable for localhost

- Media Management
  - Add root folder

- Profiles
  - Add everything to Any except: BlueRays, top Raw-HD for movies, BR-DISK for movies (leave just remuxes)
  - Upgrades allowed, until Bluray2160p Remux
  - Copy to BadTv quality, disable all 4k and Bluray-1080p Remux, upgrade till Web 1080p
  - Remove all other profiles
  - Edit Delay profile: prefer Torrent
  - (todo: consider setting up release profiles)

- Indexers: just verify them after setting up Prowlarr later

- Download clients
  - Add qBitTorrent: localhost:8080
  - (todo: consider sequential order & first and last first, for now unchecked for speed)

- Import Lists, Connect, Metadata - (todo) consider adding trakt.tv, discord/telegram/pushover/pushbullet, jellyfin, some metadata

- General: grab API key for future

- UI: dark theme

### Set up indexers - Prowlarr

- Authentication method: basic (admin, qwerty)
- Authentication required: Disable for localhost

- Indexer proxy: flaresolverr, tags - flaresolverr
- Applications: Radarr, Sonarr
- (todo: consider telegram/pushbullet)
- UI: dark theme
- Indexers (all default 25 priority, rutracker 20)
  - 1337.x, add flaresolverr tag
  - therarbg
  - kinozal.tv
  - rutracker.org (20 priority)
  - the pirate bay

- Click Sync App Indexers, recheck them in Sonarr & Radarr

### Set up Jellyfin

- Create MY account
- Library:
  - Movies: /data/movies + /data/downloads/manual-movies
  - Shows: /data/tvshows + /data/downloads/manual-shows
  - Home Vid/Photos: /data/downloads/custom-media
- Preferred language: english
- Country: USA
- Auto refresh metadata: 30 days
- Metadata savers: Nfo
- Save artwork
- (for now leave OFF) - trickplay and chapter images
  - They load the CPU and need video files processing, so leave them off for now, see how it goes
- Automerge series from different folders
- English/United States
- Uncheck allow remote connections

- Go to dashboard - general - login disclaimer :)
  - .loginDisclaimer { font-size: 5rem; color: #F55; }
- Dashboard - Plugins Catalog - Trakt - install, restart, setup
  - Disable everything but scrobbling (and also leave sync FROM trakt TO jellyfin ON)
  - Sign in

- TODO: WIP - set up Jellyfin user / dashboard / other users

### Set up Jellyseerr

- Connect to Jellyfin / Sonarr / Radarr
- Enable Scan too, check Default server
- Any (best) quality by default
- Import users from Jellyfin (maybe no need?)
- Request some TV Show and a Movie to see that everything works
- TODO: WIP: Set up

### Set up Kavita

- Sign up / Sign in
- TODO: WIP: Set up

### Additional Jellyfin setup (users / preferences)

- Add needed users with default settings, access to ALL libraries
