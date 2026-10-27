# Installing the WP sandbox

Written for Ubuntu 24.04 with a normal user that has sudo. Other distributions need the package names adjusted. Read `README.md` first.

Run step 1 with root, everything else as the user Claude Code runs as.

## 1. System packages and database (root)

```bash
sudo apt-get update
sudo apt-get install -y mariadb-server \
  php8.3-cli php8.3-mysql php8.3-gd php8.3-xml php8.3-bcmath php8.3-imagick php8.3-soap \
  php8.3-intl php8.3-mbstring php8.3-zip php8.3-curl \
  composer git rsync unzip curl openssl subversion util-linux jq build-essential

# MariaDB on Ubuntu listens on 127.0.0.1 by default; keep it that way (bind-address in
# /etc/mysql/mariadb.conf.d/50-server.cnf).

# The sandbox database and a socket-authenticated user named like the Linux user (no password).
# wordpress\_test% lets PHPUnit's install-wp-tests.sh create its own test databases.
U=$(logname 2>/dev/null || echo "$SUDO_USER")
sudo mysql <<SQL
CREATE DATABASE IF NOT EXISTS wpsandbox;
CREATE USER IF NOT EXISTS '$U'@'localhost' IDENTIFIED VIA unix_socket;
GRANT ALL ON wpsandbox.* TO '$U'@'localhost';
GRANT ALL ON \`wordpress\_test%\`.* TO '$U'@'localhost';
FLUSH PRIVILEGES;
SQL

# WP-CLI
sudo curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
sudo chmod +x /usr/local/bin/wp

# GitHub CLI (for plugins whose stable version comes from GitHub releases, private repos included)
sudo apt-get install -y gh

# Node 22 (Ubuntu's own nodejs is too old for current Playwright)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs

# Playwright's system libraries for headless Chromium
sudo npx -y playwright install-deps chromium
```

## 2. Dev tools (user)

PHPCS, PHPStan and PHPUnit usually come from each project's own `composer.json` (`vendor/bin/...`), which keeps versions per project. If projects do not ship them, install them globally once:

```bash
composer global config allow-plugins.dealerdirect/phpcodesniffer-composer-installer true
composer global require squizlabs/php_codesniffer wp-coding-standards/wpcs \
  phpcompatibility/phpcompatibility-wp phpstan/phpstan szepeviktor/phpstan-wordpress \
  php-stubs/woocommerce-stubs phpunit/phpunit yoast/phpunit-polyfills
echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> ~/.bashrc
```

Playwright's browser, in the user's cache (`~/.cache/ms-playwright`):

```bash
npx -y playwright install chromium
```

`gh auth login` if plugins come from private GitHub repos.

## 3. The sandbox (user)

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user
install -m 755 bin/wp-sandbox.sh ~/.local/bin/
cp wp-sandbox.conf.example ~/.config/wp-sandbox.conf   # optional: edit country, currency, port...
wp-sandbox.sh setup                                    # 3 to 5 minutes; prints the page checks at the end
```

`setup` downloads WordPress, upgrades it to the nightly, installs Purple (active) and Storefront, the latest WooCommerce pre-release and its sample products, and writes the admin login to `~/wp-sandbox/admin.env` (0600). The warnings about `exif_read_data` while importing sample images are harmless.

## 4. The daily update (user)

```bash
cp systemd/wp-sandbox.service systemd/wp-sandbox.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wp-sandbox.timer
sudo loginctl enable-linger "$USER"     # user timers run without anyone logged in
systemctl --user list-timers wp-sandbox.timer
```

Run it once by hand to see it work: `wp-sandbox.sh daily`.

## 5. Tell Claude about it

Add the text in `CLAUDE-md-snippet.md` to `~/.claude/CLAUDE.md` on this machine. Optionally allow the script without permission prompts, in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["Bash(wp-sandbox.sh:*)"] } }
```

## Removing it

```bash
systemctl --user disable --now wp-sandbox.timer
rm ~/.config/systemd/user/wp-sandbox.{service,timer} ~/.local/bin/wp-sandbox.sh ~/.config/wp-sandbox.conf
rm -rf ~/wp-sandbox
sudo mysql -e "DROP DATABASE wpsandbox; DROP USER '$USER'@'localhost';"
```

Then take the section out of `~/.claude/CLAUDE.md`.
