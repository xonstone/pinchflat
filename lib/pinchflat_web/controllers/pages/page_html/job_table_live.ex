defmodule Pinchflat.Pages.JobTableLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Tasks.TasksQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks.Task
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Diagnostics.QueueDiagnostics
  alias PinchflatWeb.CustomComponents.TextComponents

  @stuck_threshold_minutes 30

  def render(%{tasks: []} = assigns) do
    ~H"""
    <div class="mb-4 flex items-center">
      <p>Nothing Here!</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-full overflow-x-auto">
      <.table rows={@tasks} table_class="text-white">
        <:col :let={task} label="Task">
          {worker_to_task_name(task.job.worker)}
        </:col>
        <:col :let={task} label="Subject" class="truncate max-w-xs">
          <.subtle_link href={task_to_link(task)}>
            {task_to_record_name(task)}
          </.subtle_link>
        </:col>
        <:col :let={task} label="State">
          <.state_badge state={row_state(task)} />
        </:col>
        <:col :let={task} label="Attempt">
          {task.job.attempt}/{task.job.max_attempts}
        </:col>
        <:col :let={task} label="Started At">
          {format_datetime(task.job.attempted_at)}
        </:col>
        <:col :let={task} label="Error" class="max-w-xs">
          <div :if={row_state(task) in [:retryable, :stuck]}>
            <TextComponents.tooltip
              tooltip={best_error(task)}
              tooltip_class="whitespace-pre-wrap max-w-md text-xs text-left"
            >
              <span class="text-red-400 truncate block max-w-xs">
                {error_summary(task)}
              </span>
            </TextComponents.tooltip>
          </div>
        </:col>
        <:col :let={task} label="Actions">
          <div :if={row_state(task) in [:retryable, :stuck]} class="flex gap-2">
            <.icon_button
              icon_name="hero-arrow-path"
              class="h-9 w-9"
              phx-click="retry_job"
              phx-value-id={task.job_id}
              tooltip="Retry now"
            />
            <.icon_button
              icon_name="hero-x-mark"
              class="h-9 w-9 text-red-400"
              phx-click="cancel_job"
              phx-value-id={task.job_id}
              data-confirm="Cancel this job?"
              tooltip="Cancel"
            />
          </div>
        </:col>
      </.table>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    PinchflatWeb.Endpoint.subscribe("job:state")

    {:ok, assign(socket, tasks: get_tasks())}
  end

  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    {:noreply, assign(socket, tasks: get_tasks())}
  end

  def handle_event("retry_job", %{"id" => job_id}, socket) do
    _ = QueueDiagnostics.reset_job(String.to_integer(job_id))
    {:noreply, assign(socket, tasks: get_tasks())}
  end

  def handle_event("cancel_job", %{"id" => job_id}, socket) do
    _ = QueueDiagnostics.cancel_job(String.to_integer(job_id))
    {:noreply, assign(socket, tasks: get_tasks())}
  end

  defp get_tasks do
    TasksQuery.new()
    |> TasksQuery.join_job()
    |> where(^TasksQuery.in_state(["executing", "retryable"]))
    |> where(^TasksQuery.has_tag("show_in_dashboard"))
    |> order_by([t, j], desc: coalesce(j.attempted_at, j.scheduled_at))
    |> Repo.all()
    |> Repo.preload([:media_item, :source])
  end

  defp row_state(%Task{job: %Oban.Job{state: "retryable"}}), do: :retryable

  defp row_state(%Task{job: %Oban.Job{state: "executing", attempted_at: attempted_at}})
       when not is_nil(attempted_at) do
    if DateTime.diff(DateTime.utc_now(), attempted_at, :minute) > @stuck_threshold_minutes do
      :stuck
    else
      :executing
    end
  end

  defp row_state(_), do: :executing

  # Prefer the rich yt-dlp stderr captured in media_items.last_error by
  # MediaDownloader.download_for_media_item/2. Fall back to the Oban job's
  # errors array for source-level workers that have no associated media_item
  # (e.g. FastIndexingWorker) or when the task was pre-download.
  defp best_error(%Task{media_item: %MediaItem{last_error: e}}) when is_binary(e) and e != "", do: e
  defp best_error(%Task{job: %Oban.Job{errors: errs}}), do: extract_last_error(errs)
  defp best_error(_), do: "No error details"

  defp extract_last_error(errors) when is_list(errors) and length(errors) > 0 do
    errors
    |> List.last()
    |> Map.get("error", "Unknown error")
  end

  defp extract_last_error(_), do: "No error details"

  defp error_summary(task) do
    task
    |> best_error()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 80)
  end

  defp state_badge(%{state: :retryable} = assigns) do
    ~H"""
    <span class="inline-block rounded px-2 py-0.5 text-xs font-medium text-red-400 bg-red-500/20">
      Retryable
    </span>
    """
  end

  defp state_badge(%{state: :stuck} = assigns) do
    ~H"""
    <span class="inline-block rounded px-2 py-0.5 text-xs font-medium text-yellow-400 bg-yellow-500/20">
      Stuck
    </span>
    """
  end

  defp state_badge(assigns) do
    ~H"""
    <span class="inline-block rounded px-2 py-0.5 text-xs font-medium text-blue-400 bg-blue-500/20">
      Executing
    </span>
    """
  end

  defp worker_to_task_name(worker) do
    final_module_part =
      worker
      |> String.split(".")
      |> Enum.at(-1)

    map_worker_to_task_name(final_module_part)
  end

  defp map_worker_to_task_name("FastIndexingWorker"), do: "Fast Indexing Source"
  defp map_worker_to_task_name("MediaDownloadWorker"), do: "Downloading Media"
  defp map_worker_to_task_name("MediaCollectionIndexingWorker"), do: "Indexing Source"
  defp map_worker_to_task_name("MediaQualityUpgradeWorker"), do: "Upgrading Media Quality"
  defp map_worker_to_task_name("SourceMetadataStorageWorker"), do: "Fetching Source Metadata"
  defp map_worker_to_task_name(other), do: other <> " (Report to Devs)"

  defp task_to_record_name(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> source.custom_name
      %Task{media_item: mi} when mi != nil -> mi.title
      _ -> "Unknown Record"
    end
  end

  defp task_to_link(%Task{} = task) do
    case task do
      %Task{source: source} when source != nil -> ~p"/sources/#{source.id}"
      %Task{media_item: mi} when mi != nil -> ~p"/sources/#{mi.source_id}/media/#{mi}"
      _ -> "#"
    end
  end

  defp format_datetime(nil), do: ""

  defp format_datetime(datetime) do
    TextComponents.datetime_in_zone(%{datetime: datetime, format: "%Y-%m-%d %H:%M"})
  end
end
