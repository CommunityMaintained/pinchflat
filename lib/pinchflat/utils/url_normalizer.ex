defmodule Pinchflat.Utils.UrlNormalizer do
  @moduledoc """
  Utilities for normalizing YouTube URLs to standard formats.
  
  YouTube URLs can be provided in multiple formats. This module ensures that
  URLs are normalized to formats that yt-dlp can reliably process.
  """

  @doc """
  Normalizes a YouTube URL to a standard format.
  
  If the URL is a video URL with a playlist parameter (e.g., watch?v=...&list=PL...),
  it extracts the playlist ID and returns the standard playlist URL format.
  
  Otherwise, returns the URL unchanged.
  
  ## Examples
  
      iex> UrlNormalizer.normalize_url("https://www.youtube.com/watch?v=Fu1EX-eFVvs&list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ")
      "https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"
      
      iex> UrlNormalizer.normalize_url("https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ")
      "https://www.youtube.com/playlist?list=PLUbw0IXAmW2rMk5g19MrqcyebecSrrSeJ"
      
      iex> UrlNormalizer.normalize_url("https://www.youtube.com/channel/UCXXX")
      "https://www.youtube.com/channel/UCXXX"
  """
  def normalize_url(url) when is_binary(url) do
    case extract_playlist_id_from_video_url(url) do
      {:ok, playlist_id} -> "https://www.youtube.com/playlist?list=#{playlist_id}"
      :error -> url
    end
  end

  @doc """
  Extracts the playlist ID from a video URL that contains a list parameter.
  
  Returns {:ok, playlist_id} if found, :error otherwise.
  
  ## Examples
  
      iex> UrlNormalizer.extract_playlist_id_from_video_url("https://www.youtube.com/watch?v=xxx&list=PLYYY")
      {:ok, "PLYYY"}
      
      iex> UrlNormalizer.extract_playlist_id_from_video_url("https://www.youtube.com/channel/UCXXX")
      :error
  """
  def extract_playlist_id_from_video_url(url) when is_binary(url) do
    case Regex.run(~r/[?&]list=([A-Za-z0-9_-]+)/, url, capture: :all_but_first) do
      [playlist_id] -> {:ok, playlist_id}
      _ -> :error
    end
  end
end
