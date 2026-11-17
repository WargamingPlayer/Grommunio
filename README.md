# grommunio-spam-run

Learns the contents of every mailbox's **Junk Email** folder (folder `0x17`) as spam via [rspamd](https://rspamd.com/), and optionally deletes the messages afterwards. Built for [grommunio](https://grommunio.com/) / Gromox servers.

## How it works

1. Reads the list of mailboxes (`username`, `maildir`) from the grommunio MariaDB/MySQL database.
2. For each mailbox, queries its `exmdb/exchange.sqlite3` for messages in folder `0x17`.
3. For each message:
   - If a cached `.eml` exists in `<maildir>/eml/`, it is passed to `rspamc learn_spam` with the header `Learn-Type: bulk`.
   - Otherwise the message is exported with `gromox-exm2eml` and piped into `rspamc learn_spam`.
4. If deleting is enabled, the message is removed from the junk folder with `gromox-mbop delmsg`.

Output of the learn and delete commands is sent to the systemd journal under the tag `grommunio-spam-run`.

## Requirements

- `bash` (uses `${var,,}`, process substitution and `PIPESTATUS`)
- `mariadb` (from `/usr/bin`) or `mysql` client
- `sqlite3`
- `rspamc` (rspamd client)
- `gromox-exm2eml` and `gromox-mbop` (Gromox)
- `systemd-cat` (systemd)
- Read access to `/etc/gromox/mysql_adaptor.cfg` and to the mailbox directories, so run it as root or as a user with equivalent rights

## Installation

```bash
install -m 0755 grommunio-spam-run.sh /usr/local/sbin/grommunio-spam-run
```

## Usage

```
grommunio-spam-run [-d|--delete] [-n|--no-delete] [-v|--verbose]
grommunio-spam-run -?|--help
grommunio-spam-run --version
```

| Option | Description |
| --- | --- |
| `-d`, `--delete` | Delete junk messages after they have been learned. |
| `-n`, `--no-delete` | Never delete, regardless of `-d` or the config file. Always wins. |
| `-v`, `--verbose` | Show detailed progress and a summary at the end. |
| `-?`, `--help` | Show help and exit. |
| `--version` | Show version and exit. |
| `--license` | Show license and exit. |

### Examples

```bash
# Learn only, keep the messages, show what is happening
grommunio-spam-run -v

# Learn and delete
grommunio-spam-run --delete

# Config says delete, but do a safe dry-ish run this time
grommunio-spam-run -n -v
```

## Delete behavior

The first matching rule wins:

1. `-n` / `--no-delete`: never delete
2. `-d` / `--delete`: delete
3. `SPAMRUN_DELETE` in `/etc/gromox/spamrun.cfg` set to `true` or `1`: delete
4. Default: do not delete

## Configuration

### `/etc/gromox/spamrun.cfg` (optional)

```ini
SPAMRUN_DELETE = true
```

- Accepts `true`, `1`, `false`, `0` (case-insensitive).
- A missing file, a missing parameter, or any other value is treated as `false`.

### `/etc/gromox/mysql_adaptor.cfg` (required)

The standard Gromox database settings are used:

```
mysql_username
mysql_password
mysql_host
mysql_dbname
```

Defaults if a value is absent: user `root`, host `localhost`, database `grommunio`.

### Database client

If `/usr/bin/mariadb` exists it is used, otherwise the script falls back to `mysql` from `PATH`. If neither is available, the script exits with an error.

## Verbose output

With `-v` the script reports:

- the config file and `SPAMRUN_DELETE` value that was read
- the final delete decision and the reason for it
- the selected database client and connection settings (never the password)
- per mailbox: the number of junk messages found
- per message: how it was learned (cached eml or export), and the learn and delete results
- a summary: mailboxes processed, mailboxes with junk, messages seen, learned, failed and deleted

## Logging

Learn and delete output goes to the journal:

```bash
journalctl -t grommunio-spam-run
```

## Scheduling

Example cron entry running nightly at 03:30:

```cron
30 3 * * * /usr/local/sbin/grommunio-spam-run
```

Or with a systemd timer: create a oneshot service that runs the script and a timer that triggers it.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Finished, or help/version/license was shown |
| `1` | Unknown parameter, missing DB config, no MariaDB/MySQL client, or the database connection failed |

## Notes

- The database password is passed to the client on the command line, so it can briefly be visible in the process list.
- Deleting is permanent for the messages in the junk folder, so try `-v -n` first on a new setup.

## License

AGPL-3.0-or-later. Copyright 2026 Wim-Bart van der Waals.