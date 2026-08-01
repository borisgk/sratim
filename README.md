# Sratim

A lightweight media server written in Zig (0.16.0). Sratim automatically scans your media library, fetches metadata from TMDB, and serves your content via a fast, concurrent web server backed by SQLite.

## Installation

You can install Sratim automatically on any systemd-based Linux distribution (Arch Linux, Debian, Ubuntu) using our universal installation script.

Run the following command in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/borisgk/sratim/main/scripts/install.sh | sudo bash
```

### What the script does:
1. Downloads the latest compiled `x86_64` binary to `/usr/local/bin/sratim`.
2. Creates a default configuration file at `/etc/sratim/config.json`.
3. Prepares a secure data directory at `/var/lib/sratim/` for your SQLite databases.
4. Installs and starts a systemd daemon (`sratim.service`) running under a secure dynamic user.

## Configuration

After installation, the server comes with a default configuration file at `/etc/sratim/config.json`. This includes a default TMDB access token, but you can override it or change the port if needed.

```bash
sudo nano /etc/sratim/config.json
```

**Default Configuration:**
```json
{
  "port": 8000,
  "tmdb_access_token": "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI0YjY4NjgwZDI3MzVlYjdiMWVkNjIwZTQwZDNiMjYxMCIsIm5iZiI6MTY5MjE5NTc4Ny41MjQsInN1YiI6IjY0ZGNkYmNiMDAxYmJkMDQxYmY0NjhlOCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.3kiXVao5QsftRTtLu2H5mfmO8K35tCtD0siaWdeCbTw",
  "tmdb_proxy": ""
}
```

If you modify the configuration file, restart the service to apply the changes:
```bash
sudo systemctl restart sratim
```

## Managing the Server

You can manage the daemon using standard `systemctl` commands:

```bash
# Check if the server is running
systemctl status sratim

# View the live server logs
journalctl -u sratim -f

# Restart the server
sudo systemctl restart sratim
```

## Local Development

Building and testing Sratim locally is easy and safe.

1. Clone the repository.
2. Create a local `config.json` in the root of the repository.
3. Run `zig build run`.

**Safe Path Resolution:** If the application detects a `config.json` in your current working directory, it will automatically enter *Development Mode*. It will use local SQLite databases (`./sratim.db` and `./logs.db`) to ensure you never accidentally overwrite or corrupt your system-wide production databases located in `/var/lib/sratim/`.
