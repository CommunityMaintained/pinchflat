defmodule Pinchflat.Diagnostics.QueueDiagnostics do
  @moduledoc """
  Provides diagnostic information about Oban job queues.
  """

  import Ecto.Query

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaQuery
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source

  # Worker (short) names grouped by the kind of record their "id" arg points at,
  # so a diagnostics row can show what a job is actually working on.
  @media_item_workers ~w(MediaDownloadWorker MediaQualityUpgradeWorker)
  @source_workers ~w(
    MediaCollectionIndexingWorker FastIndexingWorker
    SourceMetadataStorageWorker SourceDeletionWorker FileSyncingWorker
  )
  @media_profile_workers ~w(MediaProfileDeletionWorker)

  @doc """
  Returns a list of all queue names, derived from the Oban configuration so it
  can't silently drift from the queues that actually run.
  """
  def queue_names do
    case Application.get_env(:pinchflat, Oban, [])[:queues] do
      queues when is_list(queues) -> Keyword.keys(queues)
      _ -> []
    end
  end

  @doc """
  Returns health status for all queues including job counts by state.
  """
  def get_all_queue_stats do
    Enum.map(queue_names(), fn queue_name ->
      queue_info = Oban.check_queue(queue: queue_name)
      job_counts = get_job_counts_for_queue(queue_name)

      %{
        name: queue_name,
        running: length(Map.get(queue_info, :running, [])),
        limit: Map.get(queue_info, :limit, 0),
        paused: Map.get(queue_info, :paused, false),
        available: Map.get(job_counts, :available, 0),
        scheduled: Map.get(job_counts, :scheduled, 0),
        retryable: Map.get(job_counts, :retryable, 0),
        executing: Map.get(job_counts, :executing, 0)
      }
    end)
  end

  @doc """
  Returns the jobs currently sitting in a queue (executing, available, scheduled
  or retryable), ordered so that what's running/runnable comes first. Capped by
  `limit` so a deep backlog can't blow up the diagnostics page.
  """
  def get_jobs_for_queue(queue_name, limit \\ 50) do
    queue_string = to_string(queue_name)

    from(j in Oban.Job,
      where: j.queue == ^queue_string,
      where: j.state in ["executing", "available", "scheduled", "retryable"],
      order_by: [
        asc:
          fragment(
            "CASE ? WHEN 'executing' THEN 0 WHEN 'available' THEN 1 WHEN 'retryable' THEN 2 ELSE 3 END",
            j.state
          ),
        asc: j.scheduled_at,
        asc: j.id
      ],
      limit: ^limit,
      select: %{
        id: j.id,
        worker: j.worker,
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        args: j.args,
        scheduled_at: j.scheduled_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns jobs that are in a retryable state (failed but will retry).
  """
  def get_retryable_jobs(limit \\ 50) do
    from(j in Oban.Job,
      where: j.state == "retryable",
      order_by: [desc: j.attempted_at],
      limit: ^limit,
      select: %{
        id: j.id,
        queue: j.queue,
        worker: j.worker,
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        errors: j.errors,
        args: j.args,
        attempted_at: j.attempted_at,
        scheduled_at: j.scheduled_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns jobs that have been discarded (failed and exhausted all retries).
  """
  def get_discarded_jobs(limit \\ 50) do
    from(j in Oban.Job,
      where: j.state == "discarded",
      order_by: [desc: j.discarded_at],
      limit: ^limit,
      select: %{
        id: j.id,
        queue: j.queue,
        worker: j.worker,
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        errors: j.errors,
        args: j.args,
        discarded_at: j.discarded_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Resolves an Oban job's worker + args into a human-friendly description of the
  record it's acting on (a Source, MediaItem or MediaProfile).

  Returns a map with `:type`, `:id`, `:name` and (for media items) `:source_id`,
  or `nil` when the job has no resolvable target. `:name` is `nil` when the record
  has since been deleted, so callers can still show which id it referenced.
  """
  def describe_job(worker, args) do
    short_name = worker |> to_string() |> String.split(".") |> List.last()
    id = args["id"]

    cond do
      is_nil(id) -> nil
      short_name in @media_item_workers -> describe_media_item(id)
      short_name in @source_workers -> describe_source(id)
      short_name in @media_profile_workers -> describe_media_profile(id)
      true -> nil
    end
  end

  defp describe_media_item(id) do
    item =
      from(m in MediaItem, where: m.id == ^id, select: %{source_id: m.source_id, name: m.title})
      |> Repo.one()

    case item do
      nil -> %{type: :media_item, id: id, source_id: nil, name: nil}
      %{source_id: source_id, name: name} -> %{type: :media_item, id: id, source_id: source_id, name: name}
    end
  end

  defp describe_source(id) do
    name =
      from(s in Source, where: s.id == ^id, select: coalesce(s.custom_name, s.collection_name))
      |> Repo.one()

    %{type: :source, id: id, source_id: id, name: name}
  end

  defp describe_media_profile(id) do
    name = from(p in MediaProfile, where: p.id == ^id, select: p.name) |> Repo.one()

    %{type: :media_profile, id: id, name: name}
  end

  @doc """
  Returns jobs that appear to be stuck (executing for too long or orphaned).
  A job is considered stuck if it's been "executing" for more than the threshold.
  """
  def get_stuck_jobs(threshold_minutes \\ 30) do
    threshold = DateTime.add(DateTime.utc_now(), -threshold_minutes * 60, :second)

    from(j in Oban.Job,
      where: j.state == "executing",
      where: j.attempted_at < ^threshold,
      order_by: [asc: j.attempted_at],
      select: %{
        id: j.id,
        queue: j.queue,
        worker: j.worker,
        attempt: j.attempt,
        attempted_at: j.attempted_at,
        args: j.args
      }
    )
    |> Repo.all()
  end

  @doc """
  Resets all retryable jobs by clearing their error history and marking as available.
  Returns the number of jobs reset.
  """
  def reset_retryable_jobs do
    {count, _} =
      from(j in Oban.Job,
        where: j.state == "retryable"
      )
      |> Repo.update_all(set: [state: "available", attempt: 1, errors: [], scheduled_at: DateTime.utc_now()])

    count
  end

  @doc """
  Resets a specific job by ID.

  Only retryable or discarded jobs can be reset. Executing jobs are deliberately
  excluded: a job may be genuinely running, and flipping it back to available would
  let a producer start a second copy concurrently (double execution). Orphaned
  executing jobs are recovered at boot by `Pinchflat.Boot.PreJobStartupTasks`.
  """
  def reset_job(job_id) do
    {count, _} =
      from(j in Oban.Job,
        where: j.id == ^job_id,
        where: j.state in ["retryable", "discarded"]
      )
      |> Repo.update_all(set: [state: "available", attempt: 1, errors: [], scheduled_at: DateTime.utc_now()])

    count
  end

  @doc """
  Cancels a specific job by ID.
  """
  def cancel_job(job_id) do
    case Oban.cancel_job(job_id) do
      :ok -> {:ok, :cancelled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Permanently deletes a discarded job by ID so it stops showing up in diagnostics.

  Scoped to `discarded` jobs only: deleting an available/scheduled/retryable job
  would silently drop work that's still meant to run, and Oban won't delete an
  executing job anyway.
  """
  def delete_discarded_job(job_id) do
    case Repo.get_by(Oban.Job, id: job_id, state: "discarded") do
      nil ->
        {:error, :not_found}

      job ->
        :ok = Oban.delete_job(job)
        {:ok, :deleted}
    end
  end

  @doc """
  Returns summary statistics for the system.
  """
  def get_system_stats do
    %{
      total_pending_downloads: count_pending_downloads(),
      total_downloaded: count_downloaded_media(),
      total_sources: count_sources(),
      database_size: get_database_size()
    }
  end

  # Private functions

  defp get_job_counts_for_queue(queue_name) do
    queue_string = Atom.to_string(queue_name)

    from(j in Oban.Job,
      where: j.queue == ^queue_string,
      where: j.state in ["available", "scheduled", "retryable", "executing"],
      group_by: j.state,
      select: {j.state, count(j.id)}
    )
    |> Repo.all()
    |> Enum.into(%{}, fn {state, count} -> {String.to_atom(state), count} end)
  end

  defp count_pending_downloads do
    # Reuse the canonical pending definition so this matches what the app actually
    # schedules for download (accounts for source cutoff, shorts/livestream rules,
    # title regex and duration limits) rather than every un-downloaded item.
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.pending())
    |> Repo.aggregate(:count)
  end

  defp count_downloaded_media do
    from(m in Pinchflat.Media.MediaItem,
      where: not is_nil(m.media_filepath)
    )
    |> Repo.aggregate(:count)
  end

  defp count_sources do
    Repo.aggregate(Pinchflat.Sources.Source, :count)
  end

  defp get_database_size do
    db_path = Application.get_env(:pinchflat, Pinchflat.Repo)[:database]

    if db_path && File.exists?(db_path) do
      # Include the WAL/SHM sidecar files so the figure reflects on-disk usage
      # rather than just the main database file.
      [db_path, db_path <> "-wal", db_path <> "-shm"]
      |> Enum.map(&file_size/1)
      |> Enum.sum()
      |> format_bytes()
    else
      "Unknown"
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / 1024 / 1024, 1)} MiB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GiB"
end
