#!/usr/bin/env bash
#
# rollback.sh — roll back the Tubeless/Pinchflat migrations from
# 20260805120000_add_user_agreement_settings down to and including
# 20260618215000_add_ignore_unavailable_media_to_settings (18 in all).
#
#   ./rollback.sh /path/to/pinchflat.db
#

set -euo pipefail

# Oldest first. The whole range is always reversed.
VERSIONS=(
  20260618215000 20260625174920 20260629120000 20260717120000
  20260717130000 20260717140000 20260717150000 20260718120000
  20260719120000 20260723120000 20260723130000 20260728120000
  20260730172201 20260730180000 20260731120000 20260801120000
  20260803120000 20260805120000
)

name_for() {
  case "$1" in
    20260618215000) echo "add_ignore_unavailable_media_to_settings" ;;
    20260625174920) echo "add_unavailable_fields_to_media_items" ;;
    20260629120000) echo "add_yt_dlp_update_policy_to_settings" ;;
    20260717120000) echo "remove_pro_enabled_from_settings" ;;
    20260717130000) echo "add_database_maintenance_enabled_to_settings" ;;
    20260717140000) echo "add_ignore_youtube_super_resolution_to_media_profiles" ;;
    20260717150000) echo "add_index_cutoff_date_to_sources" ;;
    20260718120000) echo "split_sponsorblock_categories_by_action" ;;
    20260719120000) echo "add_podcast_fields" ;;
    20260723120000) echo "backfill_source_slugs" ;;
    20260723130000) echo "create_reconcile_plans" ;;
    20260728120000) echo "add_proxy_settings" ;;
    20260730172201) echo "drop_settings_backup" ;;
    20260730180000) echo "add_time_format_setting" ;;
    20260731120000) echo "add_default_cookie_behaviour_setting" ;;
    20260801120000) echo "scope_search_index_update_trigger" ;;
    20260803120000) echo "add_table_density_setting" ;;
    20260805120000) echo "add_user_agreement_settings" ;;
  esac
}

NEWEST="${VERSIONS[${#VERSIONS[@]} - 1]}"
OLDEST="${VERSIONS[0]}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
info() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ $# -eq 1 ] || {
  info "usage: $(basename "$0") /path/to/pinchflat.db"
  exit 1
}
DB="$1"

[ -f "$DB" ] || die "no database at: $DB"
case "$DB" in *"'"*) die "database path contains a single quote: $DB" ;; esac
command -v sqlite3 >/dev/null 2>&1 || die "the sqlite3 CLI is not on PATH"

sqlite_version="$(sqlite3 --version | awk '{print $1}')"
[ "$(printf '%s\n3.35.0\n' "$sqlite_version" | sort -V | head -n1)" = "3.35.0" ] ||
  die "sqlite3 $sqlite_version is too old — DROP COLUMN needs 3.35.0+"

q() { sqlite3 -noheader -batch "$DB" "$1"; }

has_table() { [ -n "$(q "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$1' LIMIT 1;")" ]; }
has_column() { [ -n "$(q "SELECT 1 FROM pragma_table_info('$1') WHERE name='$2' LIMIT 1;")" ]; }
has_migration() { [ -n "$(q "SELECT 1 FROM schema_migrations WHERE version=$1 LIMIT 1;")" ]; }
trigger_sql() { q "SELECT COALESCE(sql, '') FROM sqlite_master WHERE type='trigger' AND name='$1';"; }

q "SELECT 1;" >/dev/null 2>&1 || die "cannot read $DB — is it a SQLite database?"
has_table schema_migrations || die "no schema_migrations table — not an Ecto database"

# A migration newer than this range would be left sitting on a schema its own
# migration never saw.
newer="$(q "SELECT group_concat(version, ', ') FROM (SELECT version FROM schema_migrations WHERE version > ${NEWEST} ORDER BY version);")"
[ -z "$newer" ] || die "migrations newer than ${NEWEST} are applied (${newer}) — roll those back first"

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
SQL="$(mktemp "${TMPDIR:-/tmp}/tubeless-rollback.XXXXXX.sql")"
TABLE="$(mktemp "${TMPDIR:-/tmp}/tubeless-rollback-table.XXXXXX.txt")"
trap 'rm -f "$SQL" "$TABLE"' EXIT

WORK=0
NOOPS=0
APPLIED_LIST=""
APPLIED_COUNT=0
COL_DROPS=0
COL_ADDS=0
TABLE_DROPS=0
TABLE_ADDS=0
INDEX_DROPS=0
DATA_CHANGES=0
TRIGGER_CHANGES=0

emit() { printf '%s\n' "$1" >>"$SQL"; }

act() {
  WORK=$((WORK + 1))
  case "$1" in
    index) INDEX_DROPS=$((INDEX_DROPS + 1)) ;;
    table_drop) TABLE_DROPS=$((TABLE_DROPS + 1)) ;;
    table_add) TABLE_ADDS=$((TABLE_ADDS + 1)) ;;
    col_drop) COL_DROPS=$((COL_DROPS + 1)) ;;
    col_add) COL_ADDS=$((COL_ADDS + 1)) ;;
    data) DATA_CHANGES=$((DATA_CHANGES + 1)) ;;
    trigger) TRIGGER_CHANGES=$((TRIGGER_CHANGES + 1)) ;;
  esac
}

# Indexes that actually index <table>.<column>. SQLite refuses to drop a column
# any index references, so these have to go first — and the app's own indexes
# aren't the only candidates.
indexes_on() {
  q "SELECT DISTINCT il.name FROM pragma_index_list('$1') il, pragma_index_info(il.name) ii WHERE ii.name = '$2';"
}

DROPPED_INDEXES=" "

drop_col() {
  local tbl="$1" col="$2" idx

  has_column "$tbl" "$col" || return 0

  for idx in $(indexes_on "$tbl" "$col"); do
    case "$idx" in
      sqlite_autoindex_*)
        die "$tbl.$col is covered by the implicit index $idx (a UNIQUE/PRIMARY KEY
       constraint). SQLite cannot drop that column without rebuilding the table —
       the migrations never create this, so the schema was altered by hand."
        ;;
    esac
    case "$DROPPED_INDEXES" in
      *" $idx "*) continue ;;
    esac
    DROPPED_INDEXES="${DROPPED_INDEXES}$idx "
    emit "DROP INDEX IF EXISTS $idx;"
    act index
  done

  # An index merely mentioning the column (a partial index's WHERE clause)
  # blocks the drop too, but that match is textual, so refuse rather than guess.
  for idx in $(q "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='$tbl' AND sql IS NOT NULL AND sql LIKE '%$col%';"); do
    case "$DROPPED_INDEXES" in
      *" $idx "*) continue ;;
    esac
    die "index $idx on $tbl references '$col' in its definition but does not index
       it (probably a partial index). It would block DROP COLUMN. Drop or rewrite
       $idx by hand, then re-run."
  done

  emit "ALTER TABLE $tbl DROP COLUMN $col;"
  act col_drop
}

add_col() {
  has_column "$1" "$2" && return 0
  emit "ALTER TABLE $1 ADD COLUMN $2 $3;"
  act col_add
}

emit "-- Generated $(date -u '+%Y-%m-%d %H:%M:%SZ') from the live schema of $DB."
emit "PRAGMA foreign_keys = OFF;"
emit "BEGIN TRANSACTION;"
emit ""

for ((i = ${#VERSIONS[@]} - 1; i >= 0; i--)); do
  v="${VERSIONS[$i]}"
  n="$(name_for "$v")"
  before="$WORK"

  if has_migration "$v"; then
    APPLIED_LIST="${APPLIED_LIST}${v},"
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
  fi

  emit "-- ${v}_${n}"

  case "$v" in

    20260805120000) # add_user_agreement_settings
      drop_col settings agreement_accepted_version
      drop_col settings agreement_accepted_at
      ;;

    20260803120000) # add_table_density_setting
      drop_col settings table_density
      ;;

    20260801120000) # scope_search_index_update_trigger — restore the unscoped one
      if has_table media_items_search_index; then
        case "$(trigger_sql media_items_search_index_update)" in
          *"AFTER UPDATE OF"* | "")
            emit "DROP TRIGGER IF EXISTS media_items_search_index_update;"
            emit "CREATE TRIGGER media_items_search_index_update AFTER UPDATE ON media_items BEGIN"
            emit "  UPDATE media_items_search_index SET"
            emit "    title = new.title,"
            emit "    description = new.description"
            emit "  WHERE"
            emit "    rowid = old.id;"
            emit "END;"
            act trigger
            ;;
        esac
      fi
      ;;

    20260731120000) # add_default_cookie_behaviour_setting
      drop_col settings default_cookie_behaviour
      ;;

    20260730180000) # add_time_format_setting
      drop_col settings time_format
      ;;

    20260730172201) # drop_settings_backup — its down recreates the table
      if ! has_table settings_backup; then
        emit "CREATE TABLE settings_backup ("
        emit "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        emit "  name TEXT NOT NULL,"
        emit "  value TEXT NOT NULL,"
        emit "  datatype TEXT NOT NULL,"
        emit "  inserted_at TEXT NOT NULL,"
        emit "  updated_at TEXT NOT NULL"
        emit ");"
        emit "CREATE UNIQUE INDEX settings_backup_name_index ON settings_backup (name);"
        act table_add
      fi
      ;;

    20260728120000) # add_proxy_settings
      drop_col settings proxy_covers_http
      drop_col settings proxy_url
      drop_col settings proxy_mode
      ;;

    20260723130000) # create_reconcile_plans — child table first
      if has_table reconcile_plan_items; then
        emit "DROP TABLE reconcile_plan_items;"
        act table_drop
      fi
      if has_table reconcile_plans; then
        emit "DROP TABLE reconcile_plans;"
        act table_drop
      fi
      ;;

    20260723120000) # backfill_source_slugs — down is a no-op, slugs go with the column
      ;;

    20260719120000) # add_podcast_fields (drop_col clears sources_slug_index first)
      drop_col sources slug
      drop_col media_profiles podcast_enabled
      drop_col settings podcast_url_base
      ;;

    20260718120000) # split_sponsorblock_categories_by_action
      have_mark=0
      have_remove=0
      if has_column media_profiles sponsorblock_mark_categories; then have_mark=1; fi
      if has_column media_profiles sponsorblock_remove_categories; then have_remove=1; fi

      if [ "$have_mark" = 1 ] || [ "$have_remove" = 1 ]; then
        add_col media_profiles sponsorblock_behaviour "TEXT DEFAULT 'disabled'"
        add_col media_profiles sponsorblock_categories "TEXT DEFAULT '[]'"

        # Mark first, then remove: remove wins when a profile configured both,
        # matching the migration's own `down`. Arrays are JSON text here.
        if [ "$have_mark" = 1 ]; then
          emit "UPDATE media_profiles"
          emit "SET sponsorblock_behaviour = 'mark',"
          emit "    sponsorblock_categories = sponsorblock_mark_categories"
          emit "WHERE json_array_length(COALESCE(sponsorblock_mark_categories, '[]')) > 0;"
          act data
        fi
        if [ "$have_remove" = 1 ]; then
          emit "UPDATE media_profiles"
          emit "SET sponsorblock_behaviour = 'remove',"
          emit "    sponsorblock_categories = sponsorblock_remove_categories"
          emit "WHERE json_array_length(COALESCE(sponsorblock_remove_categories, '[]')) > 0;"
          act data
        fi

        emit "UPDATE media_profiles SET sponsorblock_behaviour = 'disabled' WHERE sponsorblock_behaviour IS NULL;"
        emit "UPDATE media_profiles SET sponsorblock_categories = '[]' WHERE sponsorblock_categories IS NULL;"

        drop_col media_profiles sponsorblock_mark_categories
        drop_col media_profiles sponsorblock_remove_categories
      fi
      ;;

    20260717150000) # add_index_cutoff_date_to_sources
      drop_col sources index_cutoff_date
      ;;

    20260717140000) # add_ignore_youtube_super_resolution_to_media_profiles
      drop_col media_profiles ignore_youtube_super_resolution
      ;;

    20260717130000) # add_database_maintenance_enabled_to_settings
      drop_col settings database_maintenance_enabled
      ;;

    20260717120000) # remove_pro_enabled_from_settings — its down re-adds the column
      add_col settings pro_enabled "BOOLEAN DEFAULT 0 NOT NULL"
      ;;

    20260629120000) # add_yt_dlp_update_policy_to_settings
      drop_col settings yt_dlp_nightly_baseline
      drop_col settings yt_dlp_pinned_version
      drop_col settings yt_dlp_update_policy
      ;;

    20260625174920) # add_unavailable_fields_to_media_items
      drop_col media_items unavailable_reason
      drop_col media_items unavailable_at
      ;;

    20260618215000) # add_ignore_unavailable_media_to_settings
      drop_col settings ignore_unavailable_media
      ;;

  esac

  emit ""

  changes=$((WORK - before))
  if [ "$changes" -eq 0 ]; then
    NOOPS=$((NOOPS + 1))
  else
    printf '  %s  %-53s  %s\n' "$v" "$n" "$changes" >>"$TABLE"
  fi
done

if [ "$APPLIED_COUNT" -gt 0 ]; then
  emit "-- Forget these migrations so Ecto sees them as pending again"
  emit "DELETE FROM schema_migrations WHERE version IN (${APPLIED_LIST%,});"
  emit ""
fi

emit "COMMIT;"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
SUMMARY=""
add_part() {
  if [ "$1" -gt 0 ]; then
    if [ "$1" = 1 ]; then
      SUMMARY="${SUMMARY}${SUMMARY:+, }$1 $2"
    else
      SUMMARY="${SUMMARY}${SUMMARY:+, }$1 $3"
    fi
  fi
}
add_part "$COL_DROPS" "column dropped" "columns dropped"
add_part "$COL_ADDS" "column restored" "columns restored"
add_part "$TABLE_DROPS" "table dropped" "tables dropped"
add_part "$TABLE_ADDS" "table restored" "tables restored"
add_part "$INDEX_DROPS" "index dropped" "indexes dropped"
add_part "$TRIGGER_CHANGES" "trigger restored" "triggers restored"
add_part "$DATA_CHANGES" "data migration" "data migrations"
add_part "$APPLIED_COUNT" "migration record removed" "migration records removed"

info "Database:  $DB"
info "Range:     ${NEWEST} down to ${OLDEST}  (${APPLIED_COUNT} of ${#VERSIONS[@]} applied here)"

if [ "$WORK" -eq 0 ]; then
  info ""
  info "Nothing to do — none of these 18 migrations are present in this database."
  exit 0
fi

info ""
cat "$TABLE" >&2
if [ "$NOOPS" -gt 0 ]; then
  info ""
  info "  ${NOOPS} other migration(s) need nothing — not applied here, or already reversed."
fi
info ""
info "$SUMMARY"

# ---------------------------------------------------------------------------
# Confirm, then apply
# ---------------------------------------------------------------------------
[ -t 0 ] || die "run this from a terminal — it asks before changing anything"

info ""
printf 'Apply this rollback to %s? [y/N] ' "$DB" >&2
read -r answer
case "$answer" in
  y | Y | yes | YES) ;;
  *)
    info "Aborted — nothing changed."
    exit 0
    ;;
esac

# The app must not be running: this needs the write lock for the whole
# transaction, and a live app would keep writing underneath us.
sqlite3 -batch "$DB" "BEGIN IMMEDIATE; ROLLBACK;" >/dev/null 2>&1 ||
  die "could not take a write lock on $DB — stop Tubeless first"

backup="${DB}.pre-rollback-$(date -u '+%Y%m%d%H%M%S').bak"
sqlite3 -batch "$DB" ".backup '$backup'" || die "backup failed — refusing to continue"
info "Backup:    $backup"

# -bail => the first unexpected error aborts before COMMIT, so the open
# transaction is rolled back when sqlite3 exits.
sqlite3 -batch -bail "$DB" <"$SQL" ||
  die "rollback FAILED and was rolled back — the database is unchanged. See the error above."

info "Applied."

integrity="$(q "PRAGMA integrity_check;")"
fk="$(q "PRAGMA foreign_key_check;")"
left="$(q "SELECT COUNT(*) FROM schema_migrations WHERE version >= ${OLDEST};")"
info "Verified:  integrity ${integrity}, foreign keys ${fk:-ok}, ${left} migration records left from this range"

[ "$integrity" = "ok" ] || die "integrity check did NOT pass — restore the backup"
[ -z "$fk" ] || die "foreign key violations found — restore the backup"
