defmodule WhisprMessagingWeb.ConversationControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Services.UserService

  import Mock

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()
    user3_id = Ecto.UUID.generate()

    %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    }
  end

  describe "GET /messaging/api/v1/conversations" do
    test "lists all conversations for a user", %{user1_id: user1_id, user2_id: _user2_id} do
      # Create conversations
      {:ok, conversation1} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, conversation2} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Test Group"},
          is_active: true
        })

      # Add user1 as member
      Conversations.add_conversation_member(conversation1.id, user1_id)
      Conversations.add_conversation_member(conversation2.id, user1_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations")
        |> json_response(200)

      assert response["data"] != nil
      assert Enum.count(response["data"]) >= 2
    end

    test "returns empty list when user has no conversations", %{user1_id: user1_id} do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations")
        |> json_response(200)

      assert response["data"] == []
    end

    test "supports filtering by type", %{user1_id: user1_id} do
      # Create direct and group conversations
      {:ok, direct_conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, group_conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team Group"},
          is_active: true
        })

      Conversations.add_conversation_member(direct_conv.id, user1_id)
      Conversations.add_conversation_member(group_conv.id, user1_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations", type: "group")
        |> json_response(200)

      assert Enum.all?(response["data"], fn c -> c["type"] == "group" end)
    end

    test "requires authentication" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations")
        |> json_response(401)

      assert response["error"] != nil
    end

    # WHISPR-1256: media URLs stored in conversation metadata (group_icon_url,
    # picture_url, …) must be swapped for presigned S3 URLs so the web client
    # can render them in `<img src>` without an Authorization header.
    test "presigns group_icon_url stored in conversation metadata", %{user1_id: user1_id} do
      previous = Application.get_env(:whispr_messaging, :media_service_internal)

      Application.put_env(:whispr_messaging, :media_service_internal,
        url: "http://media-service.test",
        timeout_ms: 1_500,
        cache_ttl_ms: 60_000
      )

      WhisprMessaging.Services.MediaClient.reset_cache()

      on_exit(fn ->
        WhisprMessaging.Services.MediaClient.reset_cache()

        if previous do
          Application.put_env(:whispr_messaging, :media_service_internal, previous)
        else
          Application.delete_env(:whispr_messaging, :media_service_internal)
        end
      end)

      media_id = "94d20166-adb5-4f88-9319-06a531898116"
      blob_url = "https://whispr-preprod.roadmvn.com/media/v1/#{media_id}/blob"
      presigned = "https://minio.roadmvn.com/whispr-media/avatars/#{media_id}?X-Amz-Signature=abc"

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "WHISPR TEAM", "group_icon_url" => blob_url},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      with_mock Finch,
        build: fn :get, url, _headers ->
          assert String.ends_with?(url, "/media/v1/#{media_id}/blob")
          :req
        end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          {:ok, %Finch.Response{status: 200, body: ~s({"url":"#{presigned}"}), headers: []}}
        end do
        conn =
          build_conn()
          |> authenticated_conn(user1_id)
          |> json_conn()

        response =
          get(conn, ~p"/messaging/api/v1/conversations")
          |> json_response(200)

        rendered =
          Enum.find(response["data"], fn c -> c["id"] == conversation.id end)

        assert rendered != nil
        assert rendered["metadata"]["groupIconUrl"] == presigned
        assert rendered["metadata"]["name"] == "WHISPR TEAM"
      end
    end

    test "leaves metadata untouched when media-service is unreachable", %{user1_id: user1_id} do
      previous = Application.get_env(:whispr_messaging, :media_service_internal)

      Application.put_env(:whispr_messaging, :media_service_internal,
        url: "http://media-service.test",
        timeout_ms: 100,
        cache_ttl_ms: 60_000
      )

      WhisprMessaging.Services.MediaClient.reset_cache()

      on_exit(fn ->
        WhisprMessaging.Services.MediaClient.reset_cache()

        if previous do
          Application.put_env(:whispr_messaging, :media_service_internal, previous)
        else
          Application.delete_env(:whispr_messaging, :media_service_internal)
        end
      end)

      media_id = "c1593a9f-39c0-4da4-8c40-2bfa12ccaba5"
      blob_url = "https://whispr-preprod.roadmvn.com/media/v1/#{media_id}/blob"

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "CyberOps Team", "group_icon_url" => blob_url},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          {:error, %Mint.TransportError{reason: :timeout}}
        end do
        conn =
          build_conn()
          |> authenticated_conn(user1_id)
          |> json_conn()

        response =
          get(conn, ~p"/messaging/api/v1/conversations")
          |> json_response(200)

        rendered =
          Enum.find(response["data"], fn c -> c["id"] == conversation.id end)

        # Fail-safe: keep the original blob URL when presign fails.
        assert rendered["metadata"]["groupIconUrl"] == blob_url
      end
    end
  end

  describe "POST /messaging/api/v1/conversations (direct)" do
    test "creates a direct conversation with two users", %{user1_id: user1_id, user2_id: user2_id} do
      attrs = %{
        "type" => "direct",
        "other_user_id" => user2_id,
        "metadata" => %{"test" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["type"] == "direct"
      assert response["data"]["isActive"] == true
    end

    test "returns 403 when users are not contacts", %{user1_id: user1_id, user2_id: user2_id} do
      previous = Application.get_env(:whispr_messaging, :enforce_direct_contact, false)
      Application.put_env(:whispr_messaging, :enforce_direct_contact, true)

      on_exit(fn ->
        Application.put_env(:whispr_messaging, :enforce_direct_contact, previous)
      end)

      attrs = %{
        "type" => "direct",
        "other_user_id" => user2_id,
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      with_mock UserService,
                [:passthrough],
                check_users_are_contacts: fn ^user1_id, ^user2_id, _auth -> {:ok, false} end do
        response =
          post(conn, ~p"/messaging/api/v1/conversations", attrs)
          |> json_response(403)

        assert response["error"] != nil
      end
    end

    test "returns error when trying to create conversation with self", %{user1_id: user1_id} do
      attrs = %{
        "type" => "direct",
        "other_user_id" => user1_id,
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end

    test "returns 400 when missing other_user_id", %{user1_id: user1_id} do
      attrs = %{
        "type" => "direct",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(400)

      assert response["error"] != nil
    end
  end

  describe "POST /messaging/api/v1/conversations (group)" do
    test "creates a group conversation with multiple users", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      attrs = %{
        "type" => "group",
        "name" => "Test Group Chat",
        "member_ids" => [user2_id, user3_id],
        "metadata" => %{"description" => "Test group"}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["type"] == "group"
      # The controller might put name in metadata, response format depends on implementation
      # Usually name is top-level in response if rendered correctly
      # or in metadata
      assert response["data"]["metadata"]["name"] == "Test Group Chat"
      assert response["data"]["isActive"] == true
    end

    test "returns 422 when group name is missing", %{user1_id: user1_id, user2_id: user2_id} do
      attrs = %{
        "type" => "group",
        "member_ids" => [user2_id],
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end

    test "returns 422 when group has too few members", %{user1_id: user1_id} do
      attrs = %{
        "type" => "group",
        "name" => "Solo Group",
        "member_ids" => [],
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/conversations", attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "GET /messaging/api/v1/conversations/:id" do
    test "retrieves a conversation by ID", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["id"] == conversation.id
      assert response["data"]["type"] == "direct"
      assert response["data"]["isActive"] == true
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{fake_id}")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(403)

      assert response["error"] == "User is not a member of this conversation"
    end

    test "includes member list in response", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["members"] != nil
      assert Enum.count(response["data"]["members"]) == 2
    end

    test "includes memberUserIds in group conversation response", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Test Group"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)
      Conversations.add_conversation_member(conversation.id, user3_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      member_user_ids = response["data"]["memberUserIds"]
      assert is_list(member_user_ids)
      assert length(member_user_ids) == 3
      assert user1_id in member_user_ids
      assert user2_id in member_user_ids
      assert user3_id in member_user_ids
    end

    test "returns is_muted, is_pinned, is_archived for the authenticated user (default false)", %{
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["isMuted"] == false
      assert response["data"]["isPinned"] == false
      assert response["data"]["isArchived"] == false
    end

    test "returns is_muted true after muting the conversation", %{
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      # Mute the conversation for user1
      member = Conversations.get_conversation_member(conversation.id, user1_id)
      new_settings = Map.merge(member.settings || %{}, %{"is_muted" => true})
      Conversations.update_member_settings(member, new_settings)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["isMuted"] == true
      assert response["data"]["isPinned"] == false
      assert response["data"]["isArchived"] == false
    end
  end

  describe "PUT /messaging/api/v1/conversations/:id" do
    test "updates a group conversation name", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Old Name"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      update_attrs = %{
        "name" => "New Group Name",
        "metadata" => %{"updated" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}", update_attrs)
        |> json_response(200)

      # Name is typically in metadata for groups
      assert response["data"]["metadata"]["name"] == "New Group Name"
      assert response["data"]["metadata"]["updated"] == true
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      update_attrs = %{
        "name" => "Updated Name",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, ~p"/messaging/api/v1/conversations/#{fake_id}", update_attrs)
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Original Name"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id)

      update_attrs = %{
        "name" => "Hacked Name",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}", update_attrs)
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "returns 422 with invalid attributes", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Original Name"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      # Empty name for group should fail
      update_attrs = %{
        "name" => "",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}", update_attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "DELETE /messaging/api/v1/conversations/:id" do
    test "admin can deactivate a group conversation", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "To Delete"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id, %{"role" => "admin"})

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["isActive"] == false
    end

    test "non-admin member cannot deactivate a group (WHISPR-841)", %{
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Admin only"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id, %{"role" => "admin"})
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        delete(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(403)

      assert response["error"] == "Unauthorized"

      {:ok, reloaded} = Conversations.get_conversation(conversation.id)
      assert reloaded.is_active == true
    end

    test "any member can deactivate a direct conversation", %{
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(200)

      assert response["data"]["isActive"] == false
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, ~p"/messaging/api/v1/conversations/#{fake_id}")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Not Mine"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id, %{"role" => "admin"})

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}")
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "POST /messaging/api/v1/conversations/:id/members" do
    test "adds a member to a group conversation", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id, %{"role" => "admin"})
      Conversations.add_conversation_member(conversation.id, user2_id)

      add_attrs = %{
        "user_id" => user3_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/members",
          add_attrs
        )
        |> json_response(201)

      assert response["data"]["userId"] == user3_id
      assert response["data"]["isActive"] == true
    end

    test "non-admin member can add a member (WHISPR-1169)", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      add_attrs = %{
        "user_id" => user3_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/members",
          add_attrs
        )
        |> json_response(201)

      assert response["data"]["userId"] == user3_id
    end

    test "returns 403 when a non-member tries to add a member", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      add_attrs = %{
        "user_id" => user3_id
      }

      # user2 is not a member of the conversation
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/members",
          add_attrs
        )
        |> json_response(403)

      assert response["error"] != nil
    end
  end

  describe "DELETE /messaging/api/v1/conversations/:id/members/:user_id" do
    test "removes a member from conversation", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team"},
          is_active: true
        })

      # Add user1 as admin so they can remove members
      Conversations.add_conversation_member(conversation.id, user1_id, %{"role" => "admin"})
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response(
        delete(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/members/#{user2_id}"
        ),
        204
      )
    end

    test "returns 404 for non-existent member", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Team"},
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      fake_user_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/members/#{fake_user_id}"
        )
        |> json_response(404)

      assert response["error"] != nil
    end
  end
end
