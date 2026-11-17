#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Wim-Bart van der Waals
#
# Learn junk mail (folder 0x17) as spam for all mailboxes, and optionally
# delete the messages afterwards.
#
# Delete behavior is controlled by, in order of priority (highest first):
#   1. -n / --no-delete   : never delete, overrides everything below
#   2. -d / --delete      : always delete
#   3. SPAMRUN_DELETE in /etc/gromox/spamrun.cfg (true/1 -> delete)
#   4. default            : do not delete
#
# SPAMRUN_DELETE accepts (case-insensitive): true, 1, false, 0.
# If the config file is missing, the parameter is missing, or the value is
# invalid, it is treated as false.
#
# Database client: /usr/bin/mariadb is used when present, otherwise mysql.

# --- Program info -----------------------------------------------------------
PROGNAME=$(basename "$0")
VERSION="1.3.0"

# --- Config block -------------------------------------------------------
SPAMRUN_CFG="/etc/gromox/spamrun.cfg"
MYSQL_CFG="/etc/gromox/mysql_adaptor.cfg"
MARIADB_BIN="/usr/bin/mariadb"
LOG_TAG="grommunio-spam-run"

usage() {
  cat <<EOF
${PROGNAME} ${VERSION}

Learn junk mail (folder 0x17, "Junk Email") as spam for every mailbox
via rspamd, and optionally delete the learned messages afterwards.

Usage:
  ${PROGNAME} [-d|--delete] [-n|--no-delete] [-v|--verbose]
  ${PROGNAME} -?|--help
  ${PROGNAME} --version

Options:
  -d, --delete       Delete junk messages after they have been learned.
  -n, --no-delete    Never delete junk messages, regardless of -d/--delete
                     or SPAMRUN_DELETE in the config file. This option
                     always takes precedence.
  -v, --verbose      Show detailed processing information (database client,
                     delete decision, per-mailbox and per-message progress,
                     and a summary at the end).
  -?, --help         Show this help text and exit.
      --version      Show version information and exit.
      --license      Show licence.

Delete behavior priority (highest to lowest):
  1. -n / --no-delete            -> never delete
  2. -d / --delete               -> always delete
  3. SPAMRUN_DELETE in config    -> delete if true/1
  4. default                     -> do not delete

Configuration file: ${SPAMRUN_CFG}
  This optional file may contain a single parameter:

    SPAMRUN_DELETE = true|1|false|0

  - Matching is case-insensitive (e.g. True, TRUE, 1 are all accepted).
  - If the file does not exist, the parameter is absent, or its value is
    anything other than true/1/false/0, it is treated as SPAMRUN_DELETE=false.
  - Example:
      # ${SPAMRUN_CFG}
      SPAMRUN_DELETE = true

Database client:
  Uses ${MARIADB_BIN} if it exists, otherwise falls back to 'mysql'.

Also uses the MySQL/MariaDB connection details from:
  ${MYSQL_CFG}
  (parameters: mysql_username, mysql_password, mysql_host, mysql_dbname)
EOF
}

ARG_DELETE=0
ARG_NO_DELETE=0
ARG_VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    -d|--delete)
      ARG_DELETE=1
      ;;
    -n|--no-delete)
      ARG_NO_DELETE=1
      ;;
    -v|--verbose)
      ARG_VERBOSE=1
      ;;
    -\?|--help)
      ARG_VERBOSE=0
      usage
      exit 0
      ;;
    --version)
      ARG_VERBOSE=0
      echo "${PROGNAME} ${VERSION}"
      exit 0
      ;;
    --license)
      echo "${PROGNAME} ${VERSION}"
      echo "License: AGPL 3.0 or later"
      exit 0
      ;;
    *)
      echo "Unknown parameter: $arg"
      echo "Try '${PROGNAME} --help' for more information."
      exit 1
      ;;
  esac
done

# --- Helpers ---------------------------------------------------------------
# Print a message only when --verbose is active.
vlog() {
  if [ "${ARG_VERBOSE}" -eq 1 ]; then
    echo "$@"
  fi
}

# --- Start ---------------------------------------------------------------
vlog "${PROGNAME} ${VERSION} starting."

# --- Read SPAMRUN_DELETE from the spamrun config file --------------------
SPAMRUN_DELETE_CFG=0

if [ -e "${SPAMRUN_CFG}" ]; then
  vlog "Found '${SPAMRUN_CFG}', reading config."
  SPAMRUN_DELETE_VALUE=$(sed -ne 's/^[[:space:]]*SPAMRUN_DELETE[[:space:]]*=[[:space:]]*\(.*\)[[:space:]]*$/\1/pI' "${SPAMRUN_CFG}" | tail -n1)
  SPAMRUN_DELETE_VALUE=$(echo "${SPAMRUN_DELETE_VALUE}" | tr -d '[:space:]')
  case "${SPAMRUN_DELETE_VALUE,,}" in
    true|1)
      SPAMRUN_DELETE_CFG=1
      ;;
    *)
      SPAMRUN_DELETE_CFG=0
      ;;
  esac
  if [ -n "${SPAMRUN_DELETE_VALUE}" ]; then
    vlog "  SPAMRUN_DELETE='${SPAMRUN_DELETE_VALUE}' -> treated as $([ ${SPAMRUN_DELETE_CFG} -eq 1 ] && echo true || echo false)."
  else
    vlog "  SPAMRUN_DELETE not set in config, treated as false."
  fi
else
  vlog "Config file '${SPAMRUN_CFG}' not found, using defaults."
fi

# --- Determine final delete behavior --------------------------------------
if [ ${ARG_NO_DELETE} -eq 1 ]; then
  DO_DEL=0
  DEL_REASON="-n/--no-delete given"
elif [ ${ARG_DELETE} -eq 1 ]; then
  DO_DEL=1
  DEL_REASON="-d/--delete given"
elif [ ${SPAMRUN_DELETE_CFG} -eq 1 ]; then
  DO_DEL=1
  DEL_REASON="SPAMRUN_DELETE enabled in ${SPAMRUN_CFG}"
else
  DO_DEL=0
  DEL_REASON="default"
fi

if [ ${DO_DEL} -eq 1 ]; then
  vlog "Delete after learning: YES (${DEL_REASON})."
else
  vlog "Delete after learning: NO (${DEL_REASON})."
fi

# --- Select database client -----------------------------------------------
if [ -x "${MARIADB_BIN}" ]; then
  DB_CLIENT="${MARIADB_BIN}"
  vlog "Database client: ${DB_CLIENT} (found in /usr/bin)."
elif command -v mysql >/dev/null 2>&1; then
  DB_CLIENT=$(command -v mysql)
  vlog "Database client: ${DB_CLIENT} (${MARIADB_BIN} not found, falling back to mysql)."
else
  echo "Neither ${MARIADB_BIN} nor mysql was found. Please install a MariaDB/MySQL client."
  exit 1
fi

# --- Read database settings -----------------------------------------------
if [ ! -e "${MYSQL_CFG}" ] ; then
  echo "MySQL configuration not found. (${MYSQL_CFG})"
  exit 1
fi
vlog "Reading database settings from '${MYSQL_CFG}'."

MYSQL_USERNAME=$(sed -ne 's/mysql_username\s*=\s*\(.*\)\s*/-u\1/pI' ${MYSQL_CFG})
MYSQL_PASSWORD=$(sed -ne 's/mysql_password\s*=\s*\(.*\)\s*/-p\1/pI' ${MYSQL_CFG})
MYSQL_DBNAME=$(sed -ne 's/mysql_dbname\s*=\s*\(.*\)\s*/\1/pI' ${MYSQL_CFG})
MYSQL_HOST=$(sed -ne 's/mysql_host\s*=\s*\(.*\)\s*/-h\1/pI' ${MYSQL_CFG})
MYSQL_QUERY="SELECT username,maildir from users where id <> 0 and maildir <> \"\";"
# Note: the options are separate array elements (previously they were one
# combined string, which the client would have received as a single argument).
MYSQL_CMD=("${DB_CLIENT}" "--skip-column-names" "--skip-line-numbers" "${MYSQL_USERNAME:=-uroot}" "${MYSQL_PASSWORD:=}" "${MYSQL_HOST:=-hlocalhost}" "${MYSQL_DBNAME:=grommunio}")
SQLITE_QUERY='select message_id,mid_string from messages where parent_fid=0x17;'

vlog "Database: host='${MYSQL_HOST#-h}' user='${MYSQL_USERNAME#-u}' database='${MYSQL_DBNAME}'."

# --- Counters --------------------------------------------------------------
CNT_USERS=0
CNT_USERS_WITH_JUNK=0
CNT_MSGS=0
CNT_LEARNED=0
CNT_FAILED=0
CNT_DELETED=0

# --- Main ------------------------------------------------------------------
vlog "Testing database connection..."
if "${MYSQL_CMD[@]}" <<<"exit" &>/dev/null; then
  vlog "Database connection OK."

  # Process substitution (instead of a pipe) keeps the loop in the current
  # shell, so the counters survive and can be reported in the summary.
  while read -r USERNAME MAILDIR ; do
    CNT_USERS=$((CNT_USERS + 1))
    vlog "[${USERNAME}] Mailbox: ${MAILDIR}"

    SQLITE_DB="${MAILDIR}/exmdb/exchange.sqlite3"
    if [ ! -f "${SQLITE_DB}" ]; then
      vlog "[${USERNAME}] No exmdb database found at '${SQLITE_DB}', skipping."
      continue
    fi

    SPAMLIST=$(mktemp)
    echo "${SQLITE_QUERY}" | sqlite3 "${SQLITE_DB}" -tabs -noheader > "${SPAMLIST}"

    USER_MSGS=$(wc -l < "${SPAMLIST}")
    if [ "${USER_MSGS}" -eq 0 ]; then
      vlog "[${USERNAME}] No junk messages found."
      rm -f "${SPAMLIST}"
      continue
    fi
    CNT_USERS_WITH_JUNK=$((CNT_USERS_WITH_JUNK + 1))
    vlog "[${USERNAME}] ${USER_MSGS} junk message(s) found."

    while read -r MESSAGEID MIDSTRING; do
      CNT_MSGS=$((CNT_MSGS + 1))
      echo "Learning spam for user ${USERNAME}" | systemd-cat -t "${LOG_TAG}"
      MSGFILE="$MAILDIR/eml/$MIDSTRING"
      if [[ ! -f "$MSGFILE" ]]; then
        vlog "[${USERNAME}] Message ${MESSAGEID}: no cached eml, exporting via gromox-exm2eml."
        gromox-exm2eml -u "${USERNAME}" "${MESSAGEID}" 2>/dev/null | rspamc learn_spam | systemd-cat -t "${LOG_TAG}"
        RC=${PIPESTATUS[1]}
      else
        vlog "[${USERNAME}] Message ${MESSAGEID}: learning from ${MSGFILE}."
        rspamc learn_spam --header 'Learn-Type: bulk' "$MSGFILE" </dev/null | systemd-cat -t "${LOG_TAG}"
        RC=${PIPESTATUS[0]}
      fi

      if [ "${RC}" -eq 0 ]; then
        CNT_LEARNED=$((CNT_LEARNED + 1))
        vlog "[${USERNAME}] Message ${MESSAGEID}: learned as spam."
      else
        CNT_FAILED=$((CNT_FAILED + 1))
        vlog "[${USERNAME}] Message ${MESSAGEID}: learning FAILED (rspamc exit code ${RC})."
      fi

      if [ ${DO_DEL} -eq 1 ]; then
        /usr/sbin/gromox-mbop -u "${USERNAME}" delmsg -f 0x17 "${MESSAGEID}" </dev/null | systemd-cat -t "${LOG_TAG}"
        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
          CNT_DELETED=$((CNT_DELETED + 1))
          vlog "[${USERNAME}] Message ${MESSAGEID}: deleted from junk folder."
        else
          vlog "[${USERNAME}] Message ${MESSAGEID}: delete FAILED."
        fi
      fi
    done < "${SPAMLIST}"

    rm -f "${SPAMLIST}"
  done < <(echo "${MYSQL_QUERY}" | "${MYSQL_CMD[@]}")

  vlog "----------------------------------------"
  vlog "Summary:"
  vlog "  Mailboxes processed : ${CNT_USERS}"
  vlog "  Mailboxes with junk : ${CNT_USERS_WITH_JUNK}"
  vlog "  Junk messages seen  : ${CNT_MSGS}"
  vlog "  Learned as spam     : ${CNT_LEARNED}"
  vlog "  Learn failures      : ${CNT_FAILED}"
  if [ ${DO_DEL} -eq 1 ]; then
    vlog "  Deleted             : ${CNT_DELETED}"
  else
    vlog "  Deleted             : 0 (deleting disabled)"
  fi
  vlog "Done."
else
  echo "MySQL-Connection couldn't be established, please check your configuration." | systemd-cat -t "${LOG_TAG}" -p err
  vlog "ERROR: database connection could not be established using ${DB_CLIENT}; check ${MYSQL_CFG}."
  exit 1
fi