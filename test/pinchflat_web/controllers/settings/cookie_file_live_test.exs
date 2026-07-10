defmodule PinchflatWeb.Settings.CookieFileLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Pinchflat.Settings.CookieFileLive
  alias Pinchflat.Settings.CookieFile

  setup do
    base_dir =
      Path.join([System.tmp_dir!(), "cookie_live_test", Integer.to_string(:erlang.unique_integer([:positive]))])

    File.mkdir_p!(base_dir)
    original = Application.get_env(:pinchflat, :extras_directory)
    Application.put_env(:pinchflat, :extras_directory, base_dir)

    on_exit(fn ->
      Application.put_env(:pinchflat, :extras_directory, original)
      File.rm_rf!(base_dir)
    end)

    :ok
  end

  describe "initial rendering" do
    test "shows the Empty badge when no cookies are present", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CookieFileLive)

      assert html =~ "Empty"
      refute html =~ "Populated"
    end

    test "shows the Populated badge, download and clear when cookies exist", %{conn: conn} do
      File.write!(CookieFile.filepath(), "some-cookies")
      {:ok, _view, html} = live_isolated(conn, CookieFileLive)

      assert html =~ "Populated"
      assert html =~ "Download"
      assert html =~ "Clear"
    end
  end

  describe "clearing cookies" do
    test "blanks the file and updates the UI", %{conn: conn} do
      File.write!(CookieFile.filepath(), "some-cookies")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("button", "Clear") |> render_click()

      assert html =~ "Empty"
      refute CookieFile.present?()
    end
  end

  describe "validating cookies" do
    test "reports a valid file", %{conn: conn} do
      File.write!(CookieFile.filepath(), ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-check"
    end

    test "reports an invalid file", %{conn: conn} do
      File.write!(CookieFile.filepath(), "not a cookie file")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-x-mark"
    end

    test "reports when every cookie is expired", %{conn: conn} do
      File.write!(CookieFile.filepath(), ".youtube.com\tTRUE\t/\tTRUE\t1000\tNAME\tvalue")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-x-mark"
      assert html =~ "expired"
    end

    test "reports a mix of active and expired cookies", %{conn: conn} do
      lines = [
        ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tACTIVE\tvalue",
        ".youtube.com\tTRUE\t/\tTRUE\t1000\tEXPIRED\tvalue"
      ]

      File.write!(CookieFile.filepath(), Enum.join(lines, "\n"))
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      html = view |> element("[phx-click=validate_cookies]") |> render_click()

      assert html =~ "hero-exclamation-triangle"
      assert html =~ "1 of 2 active, 1 expired"
    end

    test "resets the validate icon after a delay", %{conn: conn} do
      File.write!(CookieFile.filepath(), ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue")
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      assert view |> element("[phx-click=validate_cookies]") |> render_click() =~ "hero-check"

      send(view.pid, :reset_validate_icon)

      assert render(view) =~ "hero-check-badge"
    end
  end

  describe "uploading cookies" do
    test "saves the uploaded file and marks it populated", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CookieFileLive)

      cookies =
        file_input(view, "#cookie-file-form", :cookies, [
          %{
            name: "cookies.txt",
            content: ".youtube.com\tTRUE\t/\tTRUE\t9999999999\tNAME\tvalue",
            type: "text/plain"
          }
        ])

      render_upload(cookies, "cookies.txt")
      html = view |> element("#cookie-file-form") |> render_submit()

      assert html =~ "Populated"
      assert CookieFile.present?()
    end
  end
end
