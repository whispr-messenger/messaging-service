defmodule WhisprMessaging.Services.MediaClientTest do
  use ExUnit.Case, async: false

  import Mock

  alias WhisprMessaging.Services.MediaClient

  @media_id "94d20166-adb5-4f88-9319-06a531898116"
  @blob_url "https://whispr-preprod.roadmvn.com/media/v1/" <> @media_id <> "/blob"
  @presigned_url "https://minio.roadmvn.com/whispr-media/avatars/" <>
                   @media_id <> "?X-Amz-Signature=abc"

  setup do
    previous = Application.get_env(:whispr_messaging, :media_service_internal)

    Application.put_env(:whispr_messaging, :media_service_internal,
      url: "http://media-service.test",
      timeout_ms: 1_500,
      cache_ttl_ms: 60_000
    )

    MediaClient.reset_cache()

    on_exit(fn ->
      MediaClient.reset_cache()

      if previous do
        Application.put_env(:whispr_messaging, :media_service_internal, previous)
      else
        Application.delete_env(:whispr_messaging, :media_service_internal)
      end
    end)

    :ok
  end

  defp ok_response(status, body) do
    {:ok, %Finch.Response{status: status, body: body, headers: []}}
  end

  describe "presign/3" do
    test "returns the presigned url returned by media-service" do
      with_mock Finch,
        build: fn :get, url, headers ->
          assert url == "http://media-service.test/media/v1/" <> @media_id <> "/blob"
          assert {"authorization", "Bearer xyz"} in headers
          assert {"accept", "application/json"} in headers
          {:built, url, headers}
        end,
        request: fn {:built, _, _}, WhisprMessaging.Finch, _opts ->
          ok_response(
            200,
            ~s({"url":"#{@presigned_url}","expiresAt":"2026-05-01T15:00:00Z"})
          )
        end do
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:ok, @presigned_url}
      end
    end

    test "uses the cache on the second call" do
      call_count = :counters.new(1, [])

      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          :counters.add(call_count, 1, 1)
          ok_response(200, ~s({"url":"#{@presigned_url}"}))
        end do
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:ok, @presigned_url}
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:ok, @presigned_url}

        # Only one network call thanks to the cache.
        assert :counters.get(call_count, 1) == 1
      end
    end

    test "returns {:error, :missing_authorization} without a token" do
      assert MediaClient.presign(@media_id, :blob, nil) == {:error, :missing_authorization}
      assert MediaClient.presign(@media_id, :blob, "") == {:error, :missing_authorization}
    end

    test "returns {:error, :unauthorized} on 401" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(401, "") end do
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:error, :unauthorized}
      end
    end

    test "returns {:error, :transient} on 5xx" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(503, "") end do
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:error, :transient}
      end
    end

    test "returns {:error, :transient} on transport errors" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          {:error, %Mint.TransportError{reason: :timeout}}
        end do
        assert MediaClient.presign(@media_id, :blob, "Bearer xyz") == {:error, :transient}
      end
    end

    test "returns {:error, :no_media} when media-service returns url=null" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"url":null,"expiresAt":null}))
        end do
        assert MediaClient.presign(@media_id, :thumbnail, "Bearer xyz") == {:error, :no_media}
      end
    end
  end

  describe "maybe_presign_url/2" do
    test "returns {:ok, presigned_url} for a recognised /media/v1 url" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"url":"#{@presigned_url}"}))
        end do
        assert MediaClient.maybe_presign_url(@blob_url, "Bearer xyz") ==
                 {:ok, @presigned_url}
      end
    end

    test "returns :unchanged when the url does not match the media pattern" do
      assert MediaClient.maybe_presign_url("https://example.com/foo.png", "Bearer xyz") ==
               :unchanged
    end

    test "returns :unchanged on errors so the caller keeps the original value" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(500, "") end do
        assert MediaClient.maybe_presign_url(@blob_url, "Bearer xyz") == :unchanged
      end
    end

    test "returns :unchanged when authorization is missing" do
      assert MediaClient.maybe_presign_url(@blob_url, nil) == :unchanged
    end

    test "matches /thumbnail urls too" do
      thumbnail_url =
        "https://whispr-preprod.roadmvn.com/media/v1/" <> @media_id <> "/thumbnail"

      with_mock Finch,
        build: fn :get, url, _headers ->
          assert String.ends_with?(url, "/thumbnail")
          :req
        end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"url":"#{@presigned_url}"}))
        end do
        assert MediaClient.maybe_presign_url(thumbnail_url, "Bearer xyz") ==
                 {:ok, @presigned_url}
      end
    end
  end

  describe "presign_metadata_urls/2" do
    test "rewrites recognised media keys, leaves the rest untouched" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"url":"#{@presigned_url}"}))
        end do
        metadata = %{
          "name" => "WHISPR TEAM",
          "description" => "demo group",
          "group_icon_url" => @blob_url,
          "non_media" => "https://example.com/foo"
        }

        result = MediaClient.presign_metadata_urls(metadata, "Bearer xyz")

        assert result["name"] == "WHISPR TEAM"
        assert result["description"] == "demo group"
        assert result["group_icon_url"] == @presigned_url
        assert result["non_media"] == "https://example.com/foo"
      end
    end

    test "returns metadata unchanged when authorization is missing" do
      metadata = %{"group_icon_url" => @blob_url}

      assert MediaClient.presign_metadata_urls(metadata, nil) == metadata
    end

    test "returns metadata unchanged when not a map" do
      assert MediaClient.presign_metadata_urls(nil, "Bearer xyz") == nil
      assert MediaClient.presign_metadata_urls("foo", "Bearer xyz") == "foo"
    end

    test "fails open: keeps the original url on a media-service error" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(500, "") end do
        metadata = %{"group_icon_url" => @blob_url}

        result = MediaClient.presign_metadata_urls(metadata, "Bearer xyz")

        assert result["group_icon_url"] == @blob_url
      end
    end
  end
end
