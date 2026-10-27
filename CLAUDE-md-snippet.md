# What to put in the machine's global CLAUDE.md

## Where it goes, and why there

`~/.claude/CLAUDE.md` on the box that has the sandbox. It is loaded into every session in every project, so any session that touches a plugin knows the sandbox exists without being told. A project's CLAUDE.md would only reach that one project, and auto-memory is recalled by relevance, so it can miss.

**If `~/.claude` is shared between machines** (a git repo or a sync), the section must say which machine it applies to, or sessions on the other machine will try to run a script that is not there. The script itself refuses to run on anything but Linux. One way: a "Which machine" note at the top of CLAUDE.md saying `uname` is `Darwin` on the laptop and `Linux` on the box, and the section below starting with "On <box name> only".

Keep it short: it costs tokens in every session. The details live in the script's header, which the section points to.

## The section

Adjust the plugin wording to whose plugins they are; drop the WooCommerce mentions if `WP_SANDBOX_WOOCOMMERCE=0`.

```markdown
## Testing WordPress plugins on this machine

This machine (only this one) has a permanent WordPress test install, run through
`~/.local/bin/wp-sandbox.sh` (its header has every command): WordPress nightly, the latest
WooCommerce beta, sample products, two themes (Storefront, classic, active; Purple, block, installed),
`WP_DEBUG_LOG` on, served only on `http://127.0.0.1:8899` and
only while a check or suite runs (never start `wp server` yourself). Before saying a plugin change
works, run it there:

- `wp-sandbox.sh work <plugin folder>` puts the working copy in, activates it, loads the front end
  and wp-admin and reports new PHP errors. Run it again after each edit. Always finish with
  `wp-sandbox.sh restore <folder>`, even when the task is abandoned: it puts the stable version back
  and deactivates it.
- Plugins stay installed but inactive between tests; only WooCommerce stays active. Activate what a
  test needs (`wp-sandbox.sh wp plugin activate <folder>`) and `restore` each one at the end.
- For a block theme test, `wp-sandbox.sh wp theme activate purple`; switch back to `storefront` at
  the end.
- Check the stable source `work` guesses the first time for a plugin; fix it with `--source`.
- When a test needs another plugin (a gateway, a multilingual plugin), add it with
  `wp-sandbox.sh add <slug | github:owner/repo | zip:path>`. It stays installed, so the install
  grows into a realistic shop over time. Never delete plugins from it; deactivate them.
- Test suites run against it: PHPUnit, PHPCS and PHPStan as usual, and Playwright headless through
  `wp-sandbox.sh run npx playwright test`, which sets the URL and admin login. Only tests that need a
  screen stay on a desktop machine.
- If `work` says another path owns the folder, another session is using it: ask before `--force`.
- `wp-sandbox.sh versions` gives the "Tested up to" line. `status` shows working copies and the last
  daily run; if that run says FATAL or the install is broken, `wp-sandbox.sh rollback`.
- A daily timer keeps everything current (nightly core, WooCommerce beta, every kept plugin to
  stable). Don't update things by hand.
- If you change the script, the timer or this section, keep the three in step.
```

## Keeping it updated

- **The script and the section move together.** When a command is added or changed, update the header (the manual) and, if sessions need to know, this section.
- **The environment updates itself** through the daily timer. Nobody should update core, WooCommerce or plugins by hand, or a working copy might be overwritten.
- **Richer over time** only works if sessions follow two rules: always `restore` (so the plugin goes back to stable, inactive, and stays installed rather than being deleted), and `add` rather than a raw `wp plugin install` (so the plugin gets a recorded source and the daily run keeps it current).
- **Inactive by default** keeps every test on the same baseline: only `WP_SANDBOX_KEEP_ACTIVE` (WooCommerce) stays on. The daily run deactivates anything a session forgot.
- **Once a week or so**, glance at `wp-sandbox.sh status`: the last daily line, any working copy left over, and any plugin besides WooCommerce still active.
