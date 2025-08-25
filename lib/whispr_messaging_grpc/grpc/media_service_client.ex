defmodule WhisprMessaging.Grpc.MediaServiceClient do
  @moduledoc """
  Client gRPC pour communiquer avec media-service
  selon la documentation system_design.md
  """
  
  require Logger

  @service_name "media-service"
  @default_timeout 5_000

  ## Fonctions publiques d'interface

  @doc """
  Valider l'accès à un média
  """
  def validate_media_access(media_id, user_id, conversation_id, access_type \\ "read") do
    request = %{
      media_id: media_id,
      user_id: user_id,
      conversation_id: conversation_id,
      access_type: access_type
    }
    
    Logger.debug("Validating media access", %{
      media_id: media_id,
      user_id: user_id,
      conversation_id: conversation_id,
      access_type: access_type
    })
    
    case make_grpc_call(:validate_media_access, request) do
      {:ok, response} ->
        if response.access_granted do
          {:ok, %{
            metadata: parse_media_metadata(response.metadata),
            permissions: response.permissions
          }}
        else
          {:error, response.reason}
        end
        
      {:error, reason} ->
        Logger.error("Failed to validate media access", %{
          error: reason,
          media_id: media_id,
          user_id: user_id
        })
        {:error, reason}
    end
  end

  @doc """
  Lier un média à un message
  """
  def link_media_to_message(media_id, message_id, conversation_id, user_id) do
    request = %{
      media_id: media_id,
      message_id: message_id,
      conversation_id: conversation_id,
      user_id: user_id
    }
    
    Logger.debug("Linking media to message", %{
      media_id: media_id,
      message_id: message_id,
      conversation_id: conversation_id
    })
    
    case make_grpc_call(:link_media_to_message, request) do
      {:ok, response} ->
        if response.success do
          {:ok, %{
            link_id: response.link_id,
            linked_at: response.linked_at
          }}
        else
          {:error, response.message}
        end
        
      {:error, reason} ->
        Logger.error("Failed to link media to message", %{
          error: reason,
          media_id: media_id,
          message_id: message_id
        })
        {:error, reason}
    end
  end

  @doc """
  Obtenir les métadonnées d'un média
  """
  def get_media_metadata(media_id, user_id, include_thumbnails \\ false) do
    request = %{
      media_id: media_id,
      user_id: user_id,
      include_thumbnails: include_thumbnails
    }
    
    Logger.debug("Getting media metadata", %{
      media_id: media_id,
      user_id: user_id,
      include_thumbnails: include_thumbnails
    })
    
    case make_grpc_call(:get_media_metadata, request) do
      {:ok, response} ->
        if response.found do
          {:ok, parse_media_metadata(response.metadata)}
        else
          {:error, :media_not_found}
        end
        
      {:error, reason} ->
        Logger.error("Failed to get media metadata", %{
          error: reason,
          media_id: media_id
        })
        {:error, reason}
    end
  end

  @doc """
  Valider les métadonnées d'un média avant envoi
  """
  def validate_media_metadata(filename, content_type, file_size, user_id, conversation_id) do
    request = %{
      filename: filename,
      content_type: content_type,
      file_size: file_size,
      user_id: user_id,
      conversation_id: conversation_id
    }
    
    Logger.debug("Validating media metadata", %{
      filename: filename,
      content_type: content_type,
      file_size: file_size
    })
    
    case make_grpc_call(:validate_media_metadata, request) do
      {:ok, response} ->
        if response.is_valid do
          {:ok, %{
            suggested_metadata: response.suggested_metadata
          }}
        else
          {:error, %{
            errors: response.errors,
            warnings: response.warnings
          }}
        end
        
      {:error, reason} ->
        Logger.error("Failed to validate media metadata", %{
          error: reason,
          filename: filename
        })
        {:error, reason}
    end
  end

  ## Fonctions privées

  defp make_grpc_call(method, request, _timeout \\ @default_timeout) do
    case get_connection() do
      {:ok, _connection} ->
        try do
          # Ici nous simulons l'appel gRPC pour l'instant
          # TODO: Implémenter l'appel gRPC réel avec grpcbox
          simulate_grpc_call(method, request)
        catch
          :exit, reason ->
            Logger.error("gRPC call failed with exit", %{
              method: method,
              reason: reason,
              service: @service_name
            })
            {:error, {:grpc_exit, reason}}
            
          kind, reason ->
            Logger.error("gRPC call failed with exception", %{
              method: method,
              kind: kind,
              reason: reason,
              service: @service_name
            })
            {:error, {:grpc_exception, {kind, reason}}}
        end
        
      
    end
  end

  defp get_connection do
    # TODO: Implémenter la gestion des connexions gRPC avec pool
    # Pour l'instant, simuler une connexion réussie
    {:ok, :mock_connection}
  end

  # defp parse_media_metadata(nil), do: nil
  defp parse_media_metadata(metadata) do
    %{
      media_id: metadata.media_id,
      filename: metadata.filename,
      content_type: metadata.content_type,
      file_size: metadata.file_size,
      width: metadata.width,
      height: metadata.height,
      duration_seconds: metadata.duration_seconds,
      upload_status: metadata.upload_status,
      thumbnail_urls: metadata.thumbnail_urls,
      custom_metadata: metadata.custom_metadata,
      created_at: metadata.created_at,
      expires_at: metadata.expires_at
    }
  end

  # Simulation temporaire des appels gRPC pour les tests
  defp simulate_grpc_call(:validate_media_access, request) do
    # Simulation basique : autoriser l'accès aux médias
    {:ok, %{
      access_granted: true,
      reason: "authorized",
      metadata: %{
        media_id: request.media_id,
        filename: "test_file.jpg",
        content_type: "image/jpeg",
        file_size: 1024,
        width: 1920,
        height: 1080,
        duration_seconds: 0,
        upload_status: "ready",
        thumbnail_urls: [],
        custom_metadata: %{},
        created_at: DateTime.utc_now() |> DateTime.to_unix(),
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      },
      permissions: ["read", "link"]
    }}
  end

  defp simulate_grpc_call(:link_media_to_message, _request) do
    # Simulation basique : lien créé avec succès
    {:ok, %{
      success: true,
      message: "Media linked successfully",
      link_id: UUID.uuid4(),
      linked_at: DateTime.utc_now() |> DateTime.to_unix()
    }}
  end

  defp simulate_grpc_call(:get_media_metadata, request) do
    # Simulation basique avec métadonnées factices
    {:ok, %{
      found: true,
      metadata: %{
        media_id: request.media_id,
        filename: "example_media.jpg",
        content_type: "image/jpeg",
        file_size: 2048,
        width: 1920,
        height: 1080,
        duration_seconds: 0,
        upload_status: "ready",
        thumbnail_urls: if(request.include_thumbnails, do: ["thumb1.jpg", "thumb2.jpg"], else: []),
        custom_metadata: %{},
        created_at: DateTime.utc_now() |> DateTime.to_unix(),
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      }
    }}
  end

  defp simulate_grpc_call(:validate_media_metadata, request) do
    # Simulation basique : validation réussie
    max_size = 10 * 1024 * 1024 # 10MB
    
    if request.file_size > max_size do
      {:ok, %{
        is_valid: false,
        errors: ["File size exceeds maximum allowed size"],
        warnings: [],
        suggested_metadata: %{}
      }}
    else
      {:ok, %{
        is_valid: true,
        errors: [],
        warnings: [],
        suggested_metadata: %{
          "optimized_filename" => request.filename,
          "suggested_compression" => "medium"
        }
      }}
    end
  end

  defp simulate_grpc_call(method, _request) do
    Logger.warning("Unimplemented gRPC method simulation", %{method: method})
    {:error, :method_not_implemented}
  end
end
