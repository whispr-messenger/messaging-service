defmodule WhisprMessagingWeb.AttachmentValidationTest do
  @moduledoc """
  Unit tests for the validation helpers extracted from `AttachmentController`.
  Covers every branch (allow / deny, large file, missing path, member /
  non-member access).
  """
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessagingWeb.AttachmentValidation

  describe "validate_file_size/1" do
    test "returns :ok for a small existing file" do
      path = Path.join(System.tmp_dir!(), "av_small_#{System.unique_integer([:positive])}.bin")
      File.write!(path, "tiny")

      try do
        assert AttachmentValidation.validate_file_size(%{path: path}) == :ok
      after
        File.rm(path)
      end
    end

    test "returns {:error, :file_too_large} when over 50MB" do
      # We don't want to actually allocate 50MB on disk, so we simulate via
      # a file we then check the size of in a higher boundary. To keep the
      # test cheap, we write 51 MB sparse content with truncate.
      path = Path.join(System.tmp_dir!(), "av_big_#{System.unique_integer([:positive])}.bin")
      file = File.open!(path, [:write, :binary])

      try do
        # 51 MB sparse file: seek to size-1 then write 1 byte
        :file.position(file, 51 * 1024 * 1024 - 1)
        IO.binwrite(file, <<0>>)
        File.close(file)

        assert AttachmentValidation.validate_file_size(%{path: path}) ==
                 {:error, :file_too_large}
      after
        File.rm(path)
      end
    end

    test "returns {:error, :file_stat_failed} when path does not exist" do
      bogus = Path.join(System.tmp_dir!(), "av_nope_#{System.unique_integer([:positive])}.bin")

      assert AttachmentValidation.validate_file_size(%{path: bogus}) ==
               {:error, :file_stat_failed}
    end
  end

  describe "validate_mime_type/1" do
    test "returns :ok for every allowed MIME type" do
      for mime <- AttachmentValidation.allowed_mime_types() do
        assert AttachmentValidation.validate_mime_type(mime) == :ok
      end
    end

    test "returns {:error, :invalid_mime_type} for unknown types" do
      assert AttachmentValidation.validate_mime_type("application/x-evil") ==
               {:error, :invalid_mime_type}

      assert AttachmentValidation.validate_mime_type(nil) ==
               {:error, :invalid_mime_type}

      assert AttachmentValidation.validate_mime_type("") ==
               {:error, :invalid_mime_type}
    end
  end

  describe "validate_user_permission/2" do
    test "returns :ok when sender_id matches user_id" do
      uid = Ecto.UUID.generate()
      assert AttachmentValidation.validate_user_permission(%{sender_id: uid}, uid) == :ok
    end

    test "returns {:error, :unauthorized} on mismatch" do
      assert AttachmentValidation.validate_user_permission(
               %{sender_id: Ecto.UUID.generate()},
               Ecto.UUID.generate()
             ) == {:error, :unauthorized}
    end

    test "returns {:error, :unauthorized} when user_id is nil" do
      assert AttachmentValidation.validate_user_permission(
               %{sender_id: Ecto.UUID.generate()},
               nil
             ) == {:error, :unauthorized}
    end
  end

  describe "validate_user_access/2" do
    setup do
      uid = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(conv.id, uid)
      %{conv_id: conv.id, member: uid}
    end

    test "returns :ok for an active member", ctx do
      message = %{conversation_id: ctx.conv_id}
      assert AttachmentValidation.validate_user_access(message, ctx.member) == :ok
    end

    test "returns {:error, :unauthorized} for a stranger", ctx do
      message = %{conversation_id: ctx.conv_id}

      assert AttachmentValidation.validate_user_access(message, Ecto.UUID.generate()) ==
               {:error, :unauthorized}
    end
  end

  describe "normalize_file_type/1" do
    test "image / video / audio keep their type" do
      assert AttachmentValidation.normalize_file_type("image") == "image"
      assert AttachmentValidation.normalize_file_type("video") == "video"
      assert AttachmentValidation.normalize_file_type("audio") == "audio"
    end

    test "application and text both fold to 'document'" do
      assert AttachmentValidation.normalize_file_type("application") == "document"
      assert AttachmentValidation.normalize_file_type("text") == "document"
    end

    test "anything else folds to 'document'" do
      assert AttachmentValidation.normalize_file_type("unknown") == "document"
      assert AttachmentValidation.normalize_file_type(nil) == "document"
      assert AttachmentValidation.normalize_file_type("") == "document"
    end
  end

  describe "allowed_mime_types/0 and max_file_size/0" do
    test "allowed_mime_types/0 returns the allowlist as a non-empty list" do
      list = AttachmentValidation.allowed_mime_types()
      refute Enum.empty?(list)
      assert "image/jpeg" in list
      assert "application/pdf" in list
    end

    test "max_file_size/0 is 50 MB exactly" do
      assert AttachmentValidation.max_file_size() == 50 * 1024 * 1024
    end
  end

  describe "read_file/1" do
    test "returns {:ok, content} for an existing file" do
      path =
        Path.join(System.tmp_dir!(), "av_read_#{System.unique_integer([:positive])}.bin")

      File.write!(path, "hello")

      try do
        assert {:ok, "hello"} = AttachmentValidation.read_file(path)
      after
        File.rm(path)
      end
    end

    test "maps :enoent to :file_not_found" do
      bogus =
        Path.join(System.tmp_dir!(), "av_missing_#{System.unique_integer([:positive])}.bin")

      assert AttachmentValidation.read_file(bogus) == {:error, :file_not_found}
    end

    test "passes through other read errors (e.g., :eisdir for directories)" do
      # System.tmp_dir!() is a directory — File.read on it returns :eisdir
      result = AttachmentValidation.read_file(System.tmp_dir!())
      assert match?({:error, _}, result)
      assert elem(result, 1) != :file_not_found
    end
  end

  describe "delete_file/1" do
    test "returns :ok for an existing file" do
      path =
        Path.join(System.tmp_dir!(), "av_del_#{System.unique_integer([:positive])}.bin")

      File.write!(path, "x")
      assert AttachmentValidation.delete_file(path) == :ok
      refute File.exists?(path)
    end

    test "treats :enoent as success (idempotent delete)" do
      bogus =
        Path.join(System.tmp_dir!(), "av_already_gone_#{System.unique_integer([:positive])}.bin")

      assert AttachmentValidation.delete_file(bogus) == :ok
    end

    test "returns {:error, _} on other delete failures" do
      # Calling File.rm on a directory returns :eperm or :eisdir
      result = AttachmentValidation.delete_file(System.tmp_dir!())
      assert match?({:error, _}, result)
    end
  end
end
