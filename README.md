# TyR Media Server

This is a media server for media library management. It uses PIA WireGuard vpn provider, if you have a different VPN provider or need to use OpenVPN - you might need to tweak the scripts.

## How to start

1. Configure mandatory variables in `.env` file:

- `MASTER_FOLDER` - the folder where everything will be stored, you can use symlinks inside it to forward different things into different places if you want
- `HOSTNAME` - list of allowed hostnames for Homepage service: for example `localhost,ivanpc.local` (where ivanpc is your PC domain name)

You do not need to configure anything else in this file unless you want to.

2. Start the server:

Use `./start.sh` command, or `./start.sh --timezone Asia/Tbilisi` if you want to specify a particular timezone. By default it will remain `Etc/UTC`.

Enter your PIA credentials when prompted, they will be stored in the `.secrets` file in this folder.

3. At this point, you can test that VPN is working: open browser, set up HTTP proxy on `localhost:PROXY_PORT` (8888 by default), and check your IP address.

## How to update / upgrade

Just run `./update.sh`.

## How to configure

> Go to Homepage, you can click on everything on there so you don't need to remember specific ports.

> You can try using AI-written `configure.sh` script to do everything automatically, however it's still untested and might be unreliable.

### Set up qBitTorrent

> If you run it on a custom port (non-8080) you need to disable header host validation in the config file, otherwise it will just throw Unauthorized and won't show the sign in UI.

- To sign in to qBitTorrent first time - check temporary password in docker container logs
- Disable localhost authentication
  - WebUI -> Bypass authentication for clients on localhost
  - WebUI -> Bypass authentication for clients in whitelisted IP subnets
    - Include `172.16.0.0/12` address - docker IP ranges for local addresses
- Update admin password (WebUI, qwerty)
- Change downloads folder to /data/downloads
- Check port, restart EVERYTHING, check port again - should be changed to the one forwarded by PIA

- Behavior
  - Show external IP in status bar

- Downloads
  - Excluded file names: `*.lnk`

- Connection
  - Uncheck all 4 connections limits (global, per torrent, global upload, upload per torrent)

- Speed
  - Alternative Rate Limits: 4000 upload, 10000 download

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
    - /data/media/shows (sonarr)
    - /data/media/movies (radarr)

- Profiles
  - Delete any existing profiles except for "Any"
  - In "Any":
    - Add all possible qualities, EXCEPT BlueRays (only BlueRay Remux should be enabled)
    - Check "Upgrades Allowed" till the highest quality (Bluray-2160p Remux)
  - Edit Delay profile: prefer Torrent, instead of Usenet

- Indexers: just verify them after setting up Prowlarr later

- Download clients
  - Add qBitTorrent: localhost:8080 (leave default)

- General: grab API key for future

- UI: dark theme

### Set up indexers - Prowlarr

- Authentication method: basic/forms (admin, qwerty)
- Authentication required: Disable for localhost

- Indexer proxy (settings -> indexers): flaresolverr, tags - flaresolverr, default settings (localhost:8191)
- Apps: Radarr, Sonarr (add them using localhost address and API keys)
- UI: dark theme
- Indexers
  - 1337x (add 'flaresolverr' tag)
  - Kinozal (use your account)
  - RuTracker.org (use your account)
  - rutracker-v2 (custom, use your account)
  - TheRARBG (custom yml)

- Click Sync App Indexers, recheck them in Sonarr & Radarr

### Set up Jellyfin

- Create MY account (ewancoder)
- Create family account (family/qwerty) - access to all libraries
- Library:
  - Movies: /data/media/movies
  - Shows: /data/media/tvshows
  - Home Vid/Photos: /data/downloads/content
- Leave checked allow remote connections

For libraries:
  - Preferred language: English
  - Country: US
  - Automatically add to collection (movies)
  - Automatically merge series that are spread across multiple folders (series)
  - Automitacally refresh metadata from internet - 30 days
  - Check metadata savers - Nfo
  - Fetcher settings
    - Maximum number of backdrops per item - 4
    - Minimum backdrop width - 1200
  - Check Save artwork into media folders
  - Do NOT enable trickplay (all 3 checkboxes), nor chapters
    - (if enabled when already having media) Run task: Generate Trickplay Images
    - if enabled - uses a TON of CPU/GPU and physical TIME, just not worth it

- Dashboard - Branding - Login disclaimer - adjust text
  - Styles: .loginDisclaimer { font-size: 5rem; color: #F55; }

- Dashboard - Plugins Catalog - Trakt - install, restart, setup
  - Uncheck everything except:
    - Scrobbling
    - First 3 skips
    - Last one (don't remove items from trakttv)
  - Sign in

Other Plugins (manual installation)
  - Intro skipper (add repo: https://intro-skipper.org/manifest.json, update ctrl+f5)
    - Click on Inject CSS (skip button)
    - Scan all libraries
    - Run task: Detect and Analyze Media Segments
  - File Transformation plugin - necessary for other plugins, for tv clients etc
  - Jellyfin-Enhanced - many cool things
    - Enter TMDB api key

- Playback - Transcoding - NVENC + Enable for everything (all formats)
- User settings - do not allow transcoding for ewancoder (force direct play)

- Scan all libraries, check that content is present.
- Log in as each user, and set up for user:
  - Playback preferred audio/subtitle language - English
  - Do NOT play default track always
  - Always turn on subtitles

### Set up Seerr

- Connect to Jellyfin / Sonarr / Radarr (localhost, API)
- Enable Scan too, check Default server
- Any (best) quality by default
- Import jellyfin users

### Set up Kavita

- Sign up / Sign in
- Enable folder watching (server-general)
- Add library: /data/media/comics (server-libraries)
  - Type - Comics (flexible), not just Comics (this will fuck different comics up into a single comics)
  - All 4 file types
  - Check manage collections / manage reading lists (try them)
  - Default language: English
- In reader:
  - Layout mode: double
  - Emulate comic book
  - Save to default profile

### Set up Kapowarr

- Add root folder: /data/media/comics
- Set direct download temporary folder to: /data/downloads
- Concurrent direct downloads: 10
- Failing torrent timeout: 30
- Add torrent client: qbittorrent, localhost:8080
- (skip) cannot login to Mega due to MFA, unfortunately, but prefer logging in if you can
- Log in to ComicVine using Google SSO, get API key, add it to General settings (required for Kapowarr)
- Set up flaresolverr base url (http://localhost:8191)
- Dark theme

### Set up Jellystat

Sign up / connect to Jellyfin.
