#!/usr/bin/env bash
#
# wp-sandbox.sh - a permanent WordPress test install for Claude Code on a Linux box.
#
# One install at $WP_SANDBOX_HOME/wp: WordPress nightly, the latest WooCommerce beta or RC (stable
# when no pre-release is newer), Purple (block theme, active) and Storefront (classic theme, for
# classic tests), sample products, WP_DEBUG and WP_DEBUG_LOG on. Every
# plugin a task touches is added and then stays installed but inactive, at its latest stable
# version, so the install gets richer over time without every plugin loading in every test. Nothing in it matters: it is disposable, but it is kept rather than rebuilt.
#
# Usage:
#   wp-sandbox.sh work <path> [--as <folder>] [--source <src>] [--force]
#                                   put a working copy of a plugin over the installed one, activate
#                                   it, load WordPress and report new PHP notices, warnings, fatals
#   wp-sandbox.sh add <src> [--as <folder>]
#                                   install a plugin at its stable version, activate it for the
#                                   test, and keep it (finish with restore, which deactivates it)
#   wp-sandbox.sh check             load cron, front-end and wp-admin pages again, report new log lines
#   wp-sandbox.sh restore <folder>  put back the stable version recorded for that plugin and
#                                   deactivate it (unless it is in WP_SANDBOX_KEEP_ACTIVE)
#   wp-sandbox.sh sources           where each kept plugin's stable version comes from
#   wp-sandbox.sh status            versions, working copies, last daily run
#   wp-sandbox.sh versions          the "Tested up to WordPress x and WooCommerce y" line
#   wp-sandbox.sh wp <args...>      run WP-CLI against the install
#   wp-sandbox.sh serve             wp server on the sandbox URL (foreground, Ctrl-C stops)
#   wp-sandbox.sh run <cmd...>      start the server, run a test suite against it, stop the server.
#                                   Exports WP_BASE_URL, PLAYWRIGHT_BASE_URL and BASE_URL (the URL),
#                                   WP_ADMIN_USER, WP_ADMIN_PASS, WP_PATH, WP_CLI_BIN; unsets CI.
#   wp-sandbox.sh daily             snapshot, then nightly core, WooCommerce beta, every kept plugin
#                                   to stable, stale working copies restored, plugins left active
#                                   deactivated (systemd timer)
#   wp-sandbox.sh rollback          restore the newest snapshot (after a nightly breaks the install)
#   wp-sandbox.sh setup             first install (once; refuses if one exists)
#
# <src> is a WordPress.org slug (wporg:<slug> or just <slug>), github:<owner>/<repo> (latest release
# zip, else latest tag; private repos need gh logged in), or zip:<path>. On work, the source is
# guessed when unknown (WordPress.org if the folder is a slug there, else the git remote on GitHub)
# and recorded; --source overrides the guess.
#
# The web server is not left running. work, check and run start `wp server` for as long as they need
# HTTP and stop it after; serve keeps it up by hand. The port is shared through a lock file, so do
# not start `wp server` outside this script.
#
# A working copy is marked in state/work/<folder> with the path it came from. Another path for the
# same folder is refused without --force, so two sessions do not overwrite each other. Always finish
# with restore, for working copies and for plugins added or activated for the test. Only the plugins
# in WP_SANDBOX_KEEP_ACTIVE stay active between tests. The daily run restores working copies older
# than WP_SANDBOX_STALE_MINUTES, deactivates anything else left active and switches back to
# WP_SANDBOX_THEME.
#
# Settings: defaults below, overridden in ~/.config/wp-sandbox.conf (a shell file of VAR=value).

set -euo pipefail

if [ "$(uname)" != Linux ]; then
  echo "wp-sandbox.sh runs on Linux only." >&2
  exit 1
fi

WP_SANDBOX_HOME="$HOME/wp-sandbox"
WP_SANDBOX_PORT=8899
WP_SANDBOX_DB=wpsandbox
WP_SANDBOX_DB_USER="$(id -un)"
WP_SANDBOX_DB_SOCKET=/run/mysqld/mysqld.sock
WP_SANDBOX_WOOCOMMERCE=1
WP_SANDBOX_COUNTRY=US
WP_SANDBOX_CURRENCY=USD
WP_SANDBOX_KEEP_SNAPSHOTS=5
WP_SANDBOX_STALE_MINUTES=1200
WP_SANDBOX_KEEP_ACTIVE="woocommerce"
WP_SANDBOX_THEME=purple
# shellcheck disable=SC1090
[ -f "$HOME/.config/wp-sandbox.conf" ] && . "$HOME/.config/wp-sandbox.conf"

BASE="$WP_SANDBOX_HOME"
WP_PATH="$BASE/wp"
STATE="$BASE/state"
SNAPS="$BASE/snapshots"
SECRETS="$BASE/admin.env"
PORT="$WP_SANDBOX_PORT"
URL="http://127.0.0.1:$PORT"
LOG="$WP_PATH/wp-content/debug.log"
WOO="$WP_SANDBOX_WOOCOMMERCE"
export PHP_CLI_SERVER_WORKERS=4

mkdir -p "$STATE/work" "$SNAPS"
touch "$STATE/sources.tsv"

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
wpc() { wp --path="$WP_PATH" --quiet "$@"; }
wpo() { wp --path="$WP_PATH" "$@"; }
log_size() { stat -c %s "$LOG" 2>/dev/null || echo 0; }
plugin_dir() { echo "$WP_PATH/wp-content/plugins/$1"; }
server_start() { wp --path="$WP_PATH" server --host=127.0.0.1 --port="$PORT" >/dev/null 2>&1 & sleep 2; }
server_stop() { pkill -f "127.0.0.1:$PORT" || true; }

report_log_since() {
  local start="$1" now
  now=$(log_size)
  if [ "$now" -gt "$start" ]; then
    echo "--- New debug.log lines:"
    tail -c +"$((start + 1))" "$LOG"
    echo "---"
    if tail -c +"$((start + 1))" "$LOG" | grep -q -E "PHP (Fatal|Parse) error"; then
      echo "FATAL errors above."
      return 2
    fi
  else
    echo "debug.log: nothing new."
  fi
}

# Loads WordPress through WP-CLI, runs due cron events, then requests front-end pages and, logged
# in as admin, a few wp-admin pages over HTTP. The port is shared, so the HTTP part takes a lock.
# Extra wp-admin pages to load: WP_SANDBOX_ADMIN_PAGES="admin.php?page=foo options-general.php".
exercise() {
  local cookie product front admin
  wpc eval 'echo "";' || echo "WP-CLI load failed."
  wpc cron event run --due-now >/dev/null 2>&1 || true
  cookie=$(wpo eval 'echo AUTH_COOKIE . "=" . wp_generate_auth_cookie(1, time() + 600, "auth") . "; " . LOGGED_IN_COOKIE . "=" . wp_generate_auth_cookie(1, time() + 600, "logged_in");' 2>/dev/null)
  front="/ /?p=1"
  admin="'' plugins.php options-general.php"
  if [ "$WOO" = 1 ]; then
    product=$(wpo post list --post_type=product --posts_per_page=1 --field=ID 2>/dev/null || true)
    front="/ /shop/ /cart/ /checkout/ /my-account/ /?p=$product"
    admin="'' plugins.php edit.php?post_type=product admin.php?page=wc-orders admin.php?page=wc-settings"
  fi
  (
    flock -w 60 9
    server_start
    for p in $front; do
      printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$URL$p")" "$p"
    done
    for p in $admin ${WP_SANDBOX_ADMIN_PAGES:-}; do
      [ "$p" = "''" ] && p=""
      printf '%s /wp-admin/%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -H "Cookie: $cookie" "$URL/wp-admin/$p")" "$p"
    done
    server_stop
  ) 9>"$STATE/http.lock"
}

get_source() { awk -F'\t' -v f="$1" '$1 == f { print $2 "\t" $3 }' "$STATE/sources.tsv"; }

set_source() {
  local folder="$1" kind="$2" ref="$3"
  awk -F'\t' -v f="$folder" '$1 != f' "$STATE/sources.tsv" > "$STATE/sources.tmp"
  printf '%s\t%s\t%s\n' "$folder" "$kind" "$ref" >> "$STATE/sources.tmp"
  mv "$STATE/sources.tmp" "$STATE/sources.tsv"
}

on_wporg() {
  curl -s --max-time 30 "https://api.wordpress.org/plugins/info/1.0/$1.json" | grep -q '"slug"'
}

# Prints "kind<TAB>ref" for a <src> argument.
parse_source() {
  case "$1" in
    wporg:*) printf 'wporg\t%s\n' "${1#wporg:}" ;;
    github:*) printf 'github\t%s\n' "${1#github:}" ;;
    zip:*) printf 'zip\t%s\n' "$(realpath "${1#zip:}")" ;;
    *) printf 'wporg\t%s\n' "$1" ;;
  esac
}

# Guesses where a working copy's stable version comes from.
guess_source() {
  local folder="$1" src="$2" remote
  if on_wporg "$folder"; then
    printf 'wporg\t%s\n' "$folder"
    return
  fi
  remote=$(git -C "$src" remote get-url origin 2>/dev/null || true)
  if [[ "$remote" == *github.com* ]]; then
    printf 'github\t%s\n' "$(sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##' <<<"$remote")"
    return
  fi
  printf 'none\t-\n'
}

# Unzips a plugin zip and copies the folder holding the plugin header to plugins/<folder>.
install_zip() {
  local zip="$1" folder="$2" tmp main
  tmp=$(mktemp -d)
  unzip -q "$zip" -d "$tmp/x"
  main=$(grep -l -r --include='*.php' -m1 -E '^[[:space:]/*#@]*Plugin Name:' "$tmp/x" 2>/dev/null \
    | awk -F/ '{ print NF, $0 }' | sort -n | head -1 | cut -d' ' -f2-)
  if [ -z "$main" ]; then
    rm -rf "$tmp"
    echo "No plugin header found in $zip." >&2
    return 1
  fi
  mkdir -p "$(plugin_dir "$folder")"
  rsync -a --delete "$(dirname "$main")/" "$(plugin_dir "$folder")/"
  rm -rf "$tmp"
}

install_github() {
  local repo="$1" folder="$2" tmp tag asset
  tmp=$(mktemp -d)
  tag=$(gh release view -R "$repo" --json tagName --jq .tagName 2>/dev/null || true)
  if [ -n "$tag" ]; then
    asset=$(gh release view -R "$repo" --json assets --jq '[.assets[].name | select(endswith(".zip"))][0] // ""')
    if [ -n "$asset" ]; then
      gh release download "$tag" -R "$repo" -p "$asset" -O "$tmp/p.zip"
    else
      gh release download "$tag" -R "$repo" --archive zip -O "$tmp/p.zip"
    fi
  else
    tag=$(gh api "repos/$repo/tags" --jq '.[0].name // ""' 2>/dev/null || true)
    if [ -z "$tag" ]; then
      rm -rf "$tmp"
      echo "$folder: $repo has no release or tag." >&2
      return 1
    fi
    gh api "repos/$repo/zipball/$tag" > "$tmp/p.zip"
  fi
  install_zip "$tmp/p.zip" "$folder"
  rm -rf "$tmp"
  echo "$folder: $repo $tag."
}

# Installs the stable version of a plugin from its recorded source.
install_stable() {
  local folder="$1" kind ref
  IFS=$'\t' read -r kind ref < <(get_source "$folder")
  case "${kind:-}" in
    wporg)
      # --skip-plugins: a broken working copy must not stop its own restore.
      wpc plugin install "$ref" --force --skip-plugins --skip-themes
      echo "$folder: WordPress.org stable."
      ;;
    github) install_github "$ref" "$folder" ;;
    zip) install_zip "$ref" "$folder" && echo "$folder: $ref." ;;
    *)
      echo "$folder: no stable source recorded. Record one with: wp-sandbox.sh add <src> --as $folder" >&2
      return 1
      ;;
  esac
}

keep_active() { [[ " $WP_SANDBOX_KEEP_ACTIVE " == *" $1 "* ]]; }

restore() {
  local folder="$1"
  install_stable "$folder" || { echo "$folder: left as it is." >&2; return 1; }
  rm -f "$STATE/work/$folder"
  if ! keep_active "$folder"; then
    wpc plugin deactivate "$folder" 2>/dev/null || true
    echo "$folder: inactive."
  fi
}

wc_latest() {
  php -r '
    $j = json_decode(file_get_contents("https://api.wordpress.org/plugins/info/1.0/woocommerce.json"), true);
    $best = $j["version"];
    foreach (array_keys($j["versions"]) as $v) {
      if ($v !== "trunk" && version_compare($v, $best, ">")) { $best = $v; }
    }
    echo $best, "\t", $j["versions"][$best] ?? $j["download_link"], "\n";
  '
}

update_wc() {
  local latest url current
  IFS=$'\t' read -r latest url < <(wc_latest)
  current=$(wpo plugin get woocommerce --field=version 2>/dev/null || echo none)
  if [ "$latest" != "$current" ]; then
    wpc plugin install "$url" --force --activate
    wpc wc update 2>/dev/null || true
    echo "WooCommerce $current -> $latest"
  else
    echo "WooCommerce $current (latest)"
  fi
}

update_core() {
  wpc core update https://wordpress.org/nightly-builds/wordpress-latest.zip --force
  wpc core update-db
  echo "WordPress $(wpo core version)"
}

versions_line() {
  if [ "$WOO" = 1 ]; then
    echo "Tested up to WordPress $(wpo core version) and WooCommerce $(wpo plugin get woocommerce --field=version)"
  else
    echo "Tested up to WordPress $(wpo core version)"
  fi
}

snapshot() {
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$SNAPS/$stamp"
  wpc db export - | gzip > "$SNAPS/$stamp/db.sql.gz"
  tar -C "$BASE" -czf "$SNAPS/$stamp/wp.tgz" wp
  ls -1d "$SNAPS"/*/ | sort | head -n -"$WP_SANDBOX_KEEP_SNAPSHOTS" | xargs -r rm -rf
  echo "Snapshot $stamp"
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  setup)
    if [ -f "$WP_PATH/wp-config.php" ]; then
      echo "Already installed at $WP_PATH." >&2
      exit 1
    fi
    mkdir -p "$WP_PATH"
    wpc core download --path="$WP_PATH"
    wpc config create --dbname="$WP_SANDBOX_DB" --dbuser="$WP_SANDBOX_DB_USER" --dbpass= \
      --dbhost="localhost:$WP_SANDBOX_DB_SOCKET" --skip-check
    wpc db create 2>/dev/null || true
    wpc config set WP_DEBUG true --raw
    wpc config set WP_DEBUG_LOG true --raw
    wpc config set WP_DEBUG_DISPLAY false --raw
    wpc config set SCRIPT_DEBUG true --raw
    wpc config set WP_ENVIRONMENT_TYPE local
    wpc config set AUTOMATIC_UPDATER_DISABLED true --raw
    pass=$(openssl rand -hex 16)
    wpc core install --url="$URL" --title="WP Sandbox" --admin_user=admin \
      --admin_password="$pass" --admin_email=admin@example.com --skip-email
    umask 077
    printf '# Admin login of the WP sandbox (%s). Regenerate: new value here, then\n# wp-sandbox.sh wp user update admin --user_pass=<value>\nWP_SANDBOX_ADMIN_USER=admin\nWP_SANDBOX_ADMIN_PASS=%s\n' "$URL" "$pass" > "$SECRETS"
    umask 022
    wpc rewrite structure '/%postname%/'
    update_core
    if [ "$WOO" = 1 ]; then
      wpc theme install storefront
      wpc theme install purple
      wpc theme activate "$WP_SANDBOX_THEME"
      update_wc
      set_source woocommerce wporg woocommerce
      wpc option update woocommerce_default_country "$WP_SANDBOX_COUNTRY"
      wpc option update woocommerce_currency "$WP_SANDBOX_CURRENCY"
      wpc option update woocommerce_coming_soon 'no'
      wpc option update woocommerce_onboarding_profile '{"skipped":true}' --format=json
      wpc wc tool run install_pages --user=admin >/dev/null
      wpc plugin install wordpress-importer --activate
      wpc import "$WP_PATH/wp-content/plugins/woocommerce/sample-data/sample_products.xml" --authors=create
      wpc plugin deactivate wordpress-importer
    fi
    : > "$LOG"
    exercise
    report_log_since 0 || true
    versions_line
    echo "Admin login saved in $SECRETS"
    ;;

  work)
    src="" as="" source="" force=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --as) as="$2"; shift 2 ;;
        --source) source="$2"; shift 2 ;;
        --force) force=1; shift ;;
        *) src="$1"; shift ;;
      esac
    done
    [ -n "$src" ] && [ -d "$src" ] || { echo "work needs a plugin folder." >&2; exit 1; }
    src=$(cd "$src" && pwd)
    folder="${as:-$(basename "$src")}"
    marker="$STATE/work/$folder"
    if [ -f "$marker" ] && [ "$(head -1 "$marker")" != "$src" ] && [ "$force" -ne 1 ]; then
      echo "$folder is already a working copy from $(head -1 "$marker") (since $(sed -n 2p "$marker"))." >&2
      echo "Another session may be using it. Use --force to take it over." >&2
      exit 1
    fi
    if [ -n "$source" ]; then
      IFS=$'\t' read -r kind ref < <(parse_source "$source")
      set_source "$folder" "$kind" "$ref"
    elif [ -z "$(get_source "$folder")" ]; then
      IFS=$'\t' read -r kind ref < <(guess_source "$folder" "$src")
      set_source "$folder" "$kind" "$ref"
      echo "$folder: stable version will come from $kind $ref (wrong? rerun with --source)."
    fi
    printf '%s\n%s\n' "$src" "$(date -Is)" > "$marker"
    mkdir -p "$(plugin_dir "$folder")"
    rsync -a --delete --exclude=.git --exclude=node_modules --exclude=.github "$src/" "$(plugin_dir "$folder")/"
    start=$(log_size)
    wpc plugin activate "$folder" || echo "Activation failed (missing required plugin?)."
    exercise
    report_log_since "$start"
    echo "$folder is a working copy. Finish with: wp-sandbox.sh restore $folder"
    ;;

  add)
    [ $# -ge 1 ] || usage
    spec="$1" as=""
    shift
    [ "${1:-}" = --as ] && as="${2:-}"
    IFS=$'\t' read -r kind ref < <(parse_source "$spec")
    case "$kind" in
      wporg) folder="${as:-$ref}" ;;
      github) folder="${as:-$(basename "$ref")}" ;;
      zip) folder="${as:-$(basename "$ref" .zip)}" ;;
    esac
    if [ -f "$STATE/work/$folder" ]; then
      echo "$folder is a working copy right now; restore it first." >&2
      exit 1
    fi
    set_source "$folder" "$kind" "$ref"
    install_stable "$folder"
    start=$(log_size)
    wpc plugin activate "$folder" || echo "Activation failed (missing required plugin?)."
    exercise
    report_log_since "$start"
    ;;

  check)
    start=$(log_size)
    exercise
    report_log_since "$start"
    ;;

  restore)
    [ $# -ge 1 ] || usage
    restore "$1"
    ;;

  sources)
    column -t -s $'\t' "$STATE/sources.tsv"
    ;;

  status)
    echo "WordPress $(wpo core version), PHP $(php -r 'echo PHP_VERSION;')"
    [ "$WOO" = 1 ] && echo "WooCommerce $(wpo plugin get woocommerce --field=version)"
    echo "Working copies:"
    found=0
    for m in "$STATE"/work/*; do
      [ -f "$m" ] || continue
      found=1
      echo "  $(basename "$m"): $(head -1 "$m") since $(sed -n 2p "$m")"
    done
    [ "$found" -eq 1 ] || echo "  none"
    echo "Last daily run: $(tail -1 "$STATE/daily.log" 2>/dev/null || echo never)"
    wpo plugin list --fields=name,status,version
    ;;

  versions)
    versions_line
    ;;

  wp)
    exec wp --path="$WP_PATH" "$@"
    ;;

  run)
    [ $# -ge 1 ] || usage
    # shellcheck disable=SC1090
    . "$SECRETS"
    exec 9>"$STATE/http.lock"
    flock -w 600 9 || { echo "Port $PORT is busy (another suite or check)." >&2; exit 1; }
    server_start
    start=$(log_size)
    rc=0
    env -u CI WP_BASE_URL="$URL" PLAYWRIGHT_BASE_URL="$URL" BASE_URL="$URL" \
      WP_ADMIN_USER="$WP_SANDBOX_ADMIN_USER" WP_ADMIN_PASS="$WP_SANDBOX_ADMIN_PASS" \
      WP_PATH="$WP_PATH" WP_CLI_BIN="$(command -v wp)" "$@" || rc=$?
    server_stop
    report_log_since "$start" || true
    exit "$rc"
    ;;

  serve)
    exec 9>"$STATE/http.lock"
    flock -n 9 || { echo "Port $PORT is busy (another suite or check)." >&2; exit 1; }
    echo "Serving $URL (Ctrl-C stops)."
    wp --path="$WP_PATH" server --host=127.0.0.1 --port="$PORT"
    ;;

  daily)
    exec 8>"$STATE/daily.lock"
    flock -n 8 || { echo "A daily run is already going." >&2; exit 1; }
    start=$(log_size)
    snapshot
    for m in "$STATE"/work/*; do
      [ -f "$m" ] || continue
      if [ "$(find "$m" -mmin +"$WP_SANDBOX_STALE_MINUTES")" ]; then
        restore "$(basename "$m")" || true
      fi
    done
    update_core || echo "Core update failed."
    if [ "$WOO" = 1 ]; then
      update_wc || echo "WooCommerce update failed."
    fi
    # WordPress.org updates for everything except WooCommerce (handled above), working copies,
    # and plugins kept from GitHub or a zip (a same-named WordPress.org plugin would replace them).
    exclude="woocommerce"
    for m in "$STATE"/work/*; do
      [ -f "$m" ] && exclude="$exclude,$(basename "$m")"
    done
    while IFS=$'\t' read -r folder kind _; do
      [ "$kind" = wporg ] || exclude="$exclude,$folder"
    done < "$STATE/sources.tsv"
    wpc plugin update --all --exclude="$exclude" || true
    while IFS=$'\t' read -r folder kind _; do
      if [ "$kind" = github ] && [ ! -f "$STATE/work/$folder" ]; then
        install_stable "$folder" || true
      fi
    done < "$STATE/sources.tsv"
    wpc theme update --all || true
    wpc language core update || true
    wpc language plugin update --all || true
    for p in $(wpo plugin list --status=active --field=name 2>/dev/null); do
      if ! keep_active "$p" && [ ! -f "$STATE/work/$p" ]; then
        wpc plugin deactivate "$p" || true
        echo "$p: was left active, deactivated."
      fi
    done
    if [ "$WOO" = 1 ] && ! wpc theme is-active "$WP_SANDBOX_THEME"; then
      wpc theme activate "$WP_SANDBOX_THEME" || true
      echo "Theme was left switched, back to $WP_SANDBOX_THEME."
    fi
    exercise
    result=ok
    report_log_since "$start" || result=FATAL
    line="$(date -Is) $result WordPress $(wpo core version)"
    [ "$WOO" = 1 ] && line="$line WooCommerce $(wpo plugin get woocommerce --field=version)"
    echo "$line" >> "$STATE/daily.log"
    tail -1 "$STATE/daily.log"
    if [ "$(log_size)" -gt 10485760 ]; then
      mv "$LOG" "$LOG.1"
    fi
    ;;

  rollback)
    latest=$(ls -1d "$SNAPS"/*/ 2>/dev/null | sort | tail -1)
    [ -n "$latest" ] || { echo "No snapshots." >&2; exit 1; }
    rm -rf "$WP_PATH"
    tar -C "$BASE" -xzf "$latest/wp.tgz"
    gunzip -c "$latest/db.sql.gz" | wpc db import -
    echo "Rolled back to $(basename "$latest"). Working copy markers were left as they are."
    ;;

  *)
    usage
    ;;
esac
