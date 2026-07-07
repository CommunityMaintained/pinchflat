defmodule Pinchflat.Utils.UrlNormalizerTest do
  use ExUnit.Case

  alias Pinchflat.Utils.UrlNormalizer

  describe "normalize_url/1" do
    test "converts video URL with playlist parameter to standard playlist URL" do
      video_url = "https://www.youtube.com/watch?v=Fu1EX-eFVvs&list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"
      expected = "https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"

      assert UrlNormalizer.normalize_url(video_url) == expected
    end

    test "converts video URL with list parameter first to standard playlist URL" do
      video_url = "https://www.youtube.com/watch?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ&v=Fu1EX-eFVvs"
      expected = "https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"

      assert UrlNormalizer.normalize_url(video_url) == expected
    end

    test "leaves standard playlist URL unchanged" do
      playlist_url = "https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"

      assert UrlNormalizer.normalize_url(playlist_url) == playlist_url
    end

    test "leaves channel URL unchanged" do
      channel_url = "https://www.youtube.com/channel/UCQH2"

      assert UrlNormalizer.normalize_url(channel_url) == channel_url
    end

    test "leaves user URL unchanged" do
      user_url = "https://www.youtube.com/user/someuser"

      assert UrlNormalizer.normalize_url(user_url) == user_url
    end

    test "leaves handle URL unchanged" do
      handle_url = "https://www.youtube.com/@username"

      assert UrlNormalizer.normalize_url(handle_url) == handle_url
    end
  end

  describe "extract_playlist_id_from_video_url/1" do
    test "extracts playlist ID from video URL with list parameter" do
      video_url = "https://www.youtube.com/watch?v=xxx&list=PLYYY"

      assert UrlNormalizer.extract_playlist_id_from_video_url(video_url) == {:ok, "PLYYY"}
    end

    test "extracts playlist ID with underscores and hyphens" do
      video_url = "https://www.youtube.com/watch?v=xxx&list=PL_some-id_123"

      assert UrlNormalizer.extract_playlist_id_from_video_url(video_url) == {:ok, "PL_some-id_123"}
    end

    test "returns error for URL without list parameter" do
      video_url = "https://www.youtube.com/watch?v=xxx"

      assert UrlNormalizer.extract_playlist_id_from_video_url(video_url) == :error
    end

    test "returns error for channel URL" do
      channel_url = "https://www.youtube.com/channel/UCXXX"

      assert UrlNormalizer.extract_playlist_id_from_video_url(channel_url) == :error
    end
  end
end
