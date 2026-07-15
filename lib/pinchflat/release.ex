defmodule Pinchflat.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :pinchflat

  require Logger

  alias Pinchflat.Utils.FilesystemUtils

  # Columns this fork adds on top of upstream Pinchflat. Dropping them returns the
  # schema to a byte-for-byte match with upstream so the database can be pointed at
  # an upstream image. Grouped by the feature that introduced each one.
  @fork_only_columns [
    # "ignore unavailable media" setting
    {"settings", "ignore_unavailable_media"},
    # "surface auto-skipped unavailable media" status
    {"media_items", "unavailable_at"},
    {"media_items", "unavailable_reason"},
    # "control yt-dlp update behavior from settings" policy
    {"settings", "yt_dlp_update_policy"},
    {"settings", "yt_dlp_pinned_version"},
    {"settings", "yt_dlp_nightly_baseline"}
  ]

  # Versions of the migrations that added the columns above. They're removed from
  # `schema_migrations` alongside the columns so the ledger also matches upstream.
  # Consequence: if this fork boots again afterwards, Ecto sees these as pending
  # and re-adds the columns (the fork self-heals); upstream has no such migration
  # files, so it leaves the schema clean.
  @fork_migration_versions [
    20_260_618_215_000,
    20_260_625_174_920,
    20_260_629_120_000
  ]

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Reverts this fork's additive schema changes so the database matches upstream
  Pinchflat exactly, allowing an existing install to be pointed back at an
  upstream image with an identical schema.

  This is an opt-in operation: it drops the fork-only columns (and the data in
  them) but never touches any column upstream also has, so no upstream data is
  lost. It also removes the matching rows from `schema_migrations` so the
  migration ledger matches upstream too. It is idempotent — anything already gone
  is skipped — so it is safe to re-run.

  Intended to be invoked as a one-off command that exits on its own, e.g.:

      docker compose run --rm pinchflat bin/pinchflat eval "Pinchflat.Release.prep_for_upstream()"

  Point the container at an upstream image next and start it — upstream has no
  such migration files, so it leaves the schema clean. If this fork boots again
  instead, Ecto sees those migrations as pending and re-adds the columns (the
  fork self-heals rather than crashing on the missing columns).

  Note: functional return to upstream does not actually require this — upstream
  ignores columns it does not know about — so this only exists for users who want
  a byte-for-byte identical schema.
  """
  def prep_for_upstream do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Enum.each(@fork_only_columns, &drop_column_if_exists(repo, &1))
          Enum.each(@fork_migration_versions, &delete_migration_version(repo, &1))
        end)
    end

    Logger.warning("""
    Schema reverted to upstream Pinchflat.

    Point the container at an upstream Pinchflat image and start it. If you start
    this fork again instead, it will re-add its columns and keep working.
    """)

    :ok
  end

  def check_file_permissions do
    load_app()

    directories =
      [
        "/config",
        "/downloads",
        "/etc/yt-dlp",
        "/etc/yt-dlp/plugins",
        Application.get_env(:pinchflat, :media_directory),
        Application.get_env(:pinchflat, :tmpfile_directory),
        Application.get_env(:pinchflat, :extras_directory),
        Application.get_env(:pinchflat, :metadata_directory),
        Application.get_env(:tzdata, :data_dir)
      ]
      |> Enum.uniq()
      |> Enum.filter(&(&1 != nil))

    Enum.each(directories, fn dir ->
      Logger.info("Checking permissions for #{dir}")
      filepath = Path.join([dir, ".keep"])

      case FilesystemUtils.write_p(filepath, "") do
        :ok ->
          Logger.info("Permissions OK")

        {:error, :eacces} ->
          Logger.error(permission_denied_screed(dir))
          raise "Permission denied"

        err ->
          Logger.error("Permissions check failed: #{inspect(err)}")
          raise "Unknown error"
      end
    end)
  end

  defp drop_column_if_exists(repo, {table, column} = col) do
    if column_exists?(repo, table, column) do
      Logger.info("Dropping fork-only column #{table}.#{column}")
      execute_drop!(repo, col)
    else
      Logger.info("Column #{table}.#{column} already absent, skipping")
    end
  end

  defp delete_migration_version(repo, version) do
    Logger.info("Removing fork migration #{version} from schema_migrations")
    Ecto.Adapters.SQL.query!(repo, "DELETE FROM schema_migrations WHERE version = ?", [version])
  end

  defp column_exists?(repo, table, column) do
    # `pragma_table_info` is a table-valued function, so the table name is bound
    # as a parameter rather than interpolated.
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "SELECT name FROM pragma_table_info(?)", [table])

    Enum.any?(rows, fn [name] -> name == column end)
  end

  # SQLite DDL can't parameterize identifiers. Rather than interpolate them, each
  # drop is a fixed literal statement so the SQL is a compile-time constant (there
  # is no way for user input to reach it).
  defp execute_drop!(repo, {"settings", "ignore_unavailable_media"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"settings\" DROP COLUMN \"ignore_unavailable_media\"", [])
  end

  defp execute_drop!(repo, {"media_items", "unavailable_at"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"media_items\" DROP COLUMN \"unavailable_at\"", [])
  end

  defp execute_drop!(repo, {"media_items", "unavailable_reason"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"media_items\" DROP COLUMN \"unavailable_reason\"", [])
  end

  defp execute_drop!(repo, {"settings", "yt_dlp_update_policy"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"settings\" DROP COLUMN \"yt_dlp_update_policy\"", [])
  end

  defp execute_drop!(repo, {"settings", "yt_dlp_pinned_version"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"settings\" DROP COLUMN \"yt_dlp_pinned_version\"", [])
  end

  defp execute_drop!(repo, {"settings", "yt_dlp_nightly_baseline"}) do
    Ecto.Adapters.SQL.query!(repo, "ALTER TABLE \"settings\" DROP COLUMN \"yt_dlp_nightly_baseline\"", [])
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp permission_denied_screed(dir) do
    """
    The directory "#{dir}" is not writeable by the Docker container.

    Please ensure that the directory exists and is writeable by the Docker
    container. All setups are different, but you may be able to run something
    like this on the *host*:

      chown nobody -R <host path that maps to #{dir}>
      chmod 755 -R <host path that maps to #{dir}>

    Swapping in your real host path. Then, you should set the user running
    this container by editing your `docker run` command like so:

        docker run --user 99:100 <rest of the command>

    Or adding `user: '99:100'` to the Pinchflat service of your Docker Compose
    file. Again, there are many ways to do this depending on your setup and
    this is just one example. See issue #106 in the Pinchflat Github for more.

    No matter the case, this _is_ a permissions error and allowing the container
    to write to the directory is the only way to fix it. It is not recommended
    to run the container as `root` because files created by Pinchflat may not
    be accessible to other apps that want to modify them.
    """
  end
end
