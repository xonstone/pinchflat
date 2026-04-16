defmodule PinchflatWeb.Pages.JobTableLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.JobTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingWorker

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end

    test "shows records when present", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Subject"
    end

    test "hides jobs in scheduled/completed states", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:scheduled)
      {_source, _media_item, _task, _job} = create_media_item_job(:completed)
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end

    test "shows retryable jobs alongside executing jobs", %{conn: conn} do
      {_s1, media_item_exec, _t1, _j1} = create_media_item_job(:executing)
      {_s2, media_item_retry, _t2, _j2} = create_media_item_job(:retryable)
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ media_item_exec.title
      assert html =~ media_item_retry.title
      assert html =~ "Executing"
      assert html =~ "Retryable"
    end
  end

  describe "job rendering" do
    test "shows worker name", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Downloading Media"
    end

    test "shows the media item title", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ media_item.title
    end

    test "shows a media item link", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{media_item.source_id}/media/#{media_item}"
    end

    test "shows the source custom name", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ source.custom_name
    end

    test "shows a source link", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{source.id}"
    end

    test "renders attempt count as attempt/max_attempts", %{conn: conn} do
      {_source, _media_item, _task, job} = create_media_item_job(:retryable)

      Oban.Job
      |> where([j], j.id == ^job.id)
      |> Repo.update_all(set: [attempt: 3])

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "3/#{job.max_attempts}"
    end

    test "listens for job:state change events", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, _html} = live_isolated(conn, JobTableLive, session: %{})

      PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change", payload: nil}
    end
  end

  describe "error display" do
    test "renders media_item.last_error when present on retryable row", %{conn: conn} do
      error_text = "HTTP Error 403: Forbidden"
      {_source, _media_item, _task, _job} = create_media_item_job(:retryable, last_error: error_text)

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ error_text
    end

    test "falls back to job.errors when media_item has no last_error", %{conn: conn} do
      job_error_text = "** (RuntimeError) something blew up in the worker"
      {_source, _media_item, _task, job} = create_media_item_job(:retryable)

      Oban.Job
      |> where([j], j.id == ^job.id)
      |> Repo.update_all(set: [errors: [%{"error" => job_error_text, "at" => "2026-04-15T00:00:00Z", "attempt" => 1}]])

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      # The summary is truncated to 80 chars with whitespace collapsed, which is
      # substring-visible in the rendered HTML; the full text is in the tooltip.
      assert html =~ "** (RuntimeError) something blew up in the worker"
    end

    test "renders job.errors for source-level retryable rows (no media_item)", %{conn: conn} do
      job_error_text = "Connection refused while fetching RSS"
      {_source, _task, job} = create_source_job(:retryable)

      Oban.Job
      |> where([j], j.id == ^job.id)
      |> Repo.update_all(set: [errors: [%{"error" => job_error_text, "at" => "2026-04-15T00:00:00Z", "attempt" => 1}]])

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Connection refused while fetching RSS"
    end

    test "does not render error column content for healthy executing jobs", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:executing, last_error: "should not appear")

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      refute html =~ "should not appear"
    end
  end

  describe "retry and cancel actions" do
    test "retry_job resets the job and removes the row", %{conn: conn} do
      {_source, _media_item, _task, job} = create_media_item_job(:retryable)

      {:ok, view, html} = live_isolated(conn, JobTableLive, session: %{})
      assert html =~ "Retryable"

      new_html =
        view
        |> element("button[phx-click=\"retry_job\"][phx-value-id=\"#{job.id}\"]")
        |> render_click()

      # Row is gone once the job is no longer retryable/executing
      refute new_html =~ "Retryable"

      updated = Repo.get!(Oban.Job, job.id)
      assert updated.state == "available"
      assert updated.attempt == 1
      assert updated.errors == []
    end

    test "cancel_job cancels the job and removes the row", %{conn: conn} do
      {_source, _media_item, _task, job} = create_media_item_job(:retryable)

      {:ok, view, _html} = live_isolated(conn, JobTableLive, session: %{})

      new_html =
        view
        |> element("button[phx-click=\"cancel_job\"][phx-value-id=\"#{job.id}\"]")
        |> render_click()

      refute new_html =~ "Retryable"

      updated = Repo.get!(Oban.Job, job.id)
      assert updated.state == "cancelled"
    end

    test "no action buttons on healthy executing rows", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:executing)

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      refute html =~ ~s(phx-click="retry_job")
      refute html =~ ~s(phx-click="cancel_job")
    end
  end

  describe "stuck detection" do
    test "executing job with attempted_at > 30 min ago renders as Stuck with actions", %{conn: conn} do
      {_source, _media_item, _task, job} = create_media_item_job(:executing)

      past = DateTime.add(DateTime.utc_now(), -40 * 60, :second)

      Oban.Job
      |> where([j], j.id == ^job.id)
      |> Repo.update_all(set: [attempted_at: past])

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Stuck"
      refute html =~ "Executing"
      assert html =~ ~s(phx-click="retry_job")
    end

    test "fresh executing job renders as Executing (no actions)", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:executing)

      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Executing"
      refute html =~ "Stuck"
      refute html =~ ~s(phx-click="retry_job")
    end
  end

  defp create_media_item_job(job_state \\ :executing, media_item_attrs \\ []) do
    source = source_fixture()
    media_item = media_item_fixture(Keyword.merge([source_id: source.id], media_item_attrs))
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state), attempted_at: now])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, media_item, task, job}
  end

  defp create_source_job(job_state \\ :executing) do
    source = source_fixture()
    {:ok, task} = FastIndexingWorker.kickoff_with_task(source)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state), attempted_at: now])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, task, job}
  end
end
