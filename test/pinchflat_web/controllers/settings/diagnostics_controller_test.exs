defmodule PinchflatWeb.Settings.DiagnosticsControllerTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.JobFixtures.TestJobWorker

  describe "show" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/diagnostics")

      assert html_response(conn, 200) =~ "Diagnostics"
    end
  end

  describe "reset_retryable_jobs" do
    test "resets retryable jobs and redirects with a count", %{conn: conn} do
      job = job_in_state("retryable")

      conn = post(conn, ~p"/diagnostics/reset_retryable_jobs")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "Reset 1 retryable job(s)"
      assert %{state: "available"} = Repo.reload(job)
    end
  end

  describe "reset_job" do
    test "resets a retryable job and redirects", %{conn: conn} do
      job = job_in_state("retryable")

      conn = post(conn, ~p"/diagnostics/reset_job/#{job.id}")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "has been reset"
      assert %{state: "available"} = Repo.reload(job)
    end

    test "shows an error when the job cannot be reset", %{conn: conn} do
      job = job_in_state("executing")

      conn = post(conn, ~p"/diagnostics/reset_job/#{job.id}")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "could not be reset"
      assert %{state: "executing"} = Repo.reload(job)
    end

    test "shows an error for a non-numeric job id", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/reset_job/bogus")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "not a valid job ID"
    end
  end

  describe "requeue_job" do
    test "requeues a job and redirects", %{conn: conn} do
      job = job_in_state("executing")

      conn = post(conn, ~p"/diagnostics/requeue_job/#{job.id}")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "was requeued"
      assert %{state: "cancelled"} = Repo.reload(job)
    end

    test "shows an error when the job does not exist", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/requeue_job/12345678")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "could not be requeued"
    end

    test "shows an error for a non-numeric job id", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/requeue_job/bogus")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "not a valid job ID"
    end
  end

  describe "delete_job" do
    test "deletes a discarded job and redirects", %{conn: conn} do
      job = job_in_state("discarded")

      conn = post(conn, ~p"/diagnostics/delete_job/#{job.id}")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["info"] =~ "has been deleted"
      assert Repo.reload(job) == nil
    end

    test "shows an error when the job is not discarded", %{conn: conn} do
      job = job_in_state("available")

      conn = post(conn, ~p"/diagnostics/delete_job/#{job.id}")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "could not be deleted"
      assert Repo.reload(job)
    end

    test "shows an error for a non-numeric job id", %{conn: conn} do
      conn = post(conn, ~p"/diagnostics/delete_job/bogus")

      assert redirected_to(conn) == ~p"/diagnostics"
      assert conn.assigns[:flash]["error"] =~ "not a valid job ID"
    end
  end

  defp job_in_state(state) do
    {:ok, job} = Oban.insert(TestJobWorker.new(%{}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])

    %{job | state: state}
  end
end
