defmodule Pinchflat.YtDlp.UpdateManagerTest do
  use Pinchflat.DataCase

  alias Pinchflat.Settings
  alias Pinchflat.YtDlp.UpdateManager

  describe "policies/0" do
    test "returns every supported policy" do
      assert UpdateManager.policies() == ~w(stable nightly nightly_frozen nightly_until_stable pinned)
    end
  end

  describe "humanize_policy/1" do
    test "returns a human-friendly label for each policy" do
      assert UpdateManager.humanize_policy("stable") == "Stable"
      assert UpdateManager.humanize_policy("nightly") == "Nightly"
      assert UpdateManager.humanize_policy("nightly_frozen") == "Nightly, frozen"
      assert UpdateManager.humanize_policy("nightly_until_stable") == "Nightly until stable"
      assert UpdateManager.humanize_policy("pinned") == "Pinned"
    end

    test "falls back to Stable for unknown values" do
      assert UpdateManager.humanize_policy("what") == "Stable"
      assert UpdateManager.humanize_policy(nil) == "Stable"
    end
  end

  describe "run_scheduled_update/0 when the update fails" do
    test "still completes and does not overwrite the recorded version" do
      Settings.set(yt_dlp_update_policy: "nightly")
      Settings.set(yt_dlp_version: "2025.01.01")
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:error, "no internet"} end)
      expect(YtDlpRunnerMock, :version, fn -> {:error, "no binary"} end)

      assert :ok = UpdateManager.run_scheduled_update()
      assert {:ok, "2025.01.01"} = Settings.get(:yt_dlp_version)
    end
  end

  describe "apply_policy/0 when the version can't be read back" do
    test "does not record a nightly baseline it doesn't know" do
      Settings.set(yt_dlp_update_policy: "nightly_frozen")
      Settings.set(yt_dlp_nightly_baseline: nil)
      expect(YtDlpRunnerMock, :update, fn "nightly" -> {:ok, ""} end)
      # once for the baseline capture, once for the version refresh
      expect(YtDlpRunnerMock, :version, 2, fn -> {:error, "no binary"} end)

      assert :ok = UpdateManager.apply_policy()
      assert {:ok, nil} = Settings.get(:yt_dlp_nightly_baseline)
    end
  end
end
