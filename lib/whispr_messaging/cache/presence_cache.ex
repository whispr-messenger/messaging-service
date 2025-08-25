defmodule WhisprMessaging.Cache.PresenceCache do
  @moduledoc """
  Cache de présence utilisateur avec Redis
  selon les spécifications 6_status_indicators.md
  """
  
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  @presence_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :user_presence], 300)
  @typing_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :typing_indicator], 10)
  @conversation_presence_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :conversation_presence], 300)

  ## Présence Utilisateur

  @doc """
  Mettre à jour la présence d'un utilisateur
  """
  def set_user_presence(user_id, status, metadata \\ %{}) do
    key = presence_key(user_id)
    
    presence_data = %{
      status: status,
      last_activity: DateTime.utc_now() |> DateTime.to_iso8601(),
      devices: metadata[:devices] || [],
      node: Node.self() |> Atom.to_string()
    } |> Map.merge(metadata)
    
    commands = [
      ["HSET", key] ++ flatten_hash(presence_data),
      ["EXPIRE", key, @presence_ttl]
    ]
    
    case RedisConnection.session_command("MULTI", []) do
      {:ok, "OK"} ->
        case RedisConnection.pipeline(:session_pool, commands ++ [["EXEC"]]) do
          {:ok, _results} ->
            Logger.debug("User presence updated", %{
              user_id: user_id,
              status: status,
              ttl: @presence_ttl
            })
            :ok
            
          {:error, reason} ->
            Logger.error("Failed to update user presence", %{
              user_id: user_id,
              error: reason
            })
            {:error, reason}
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Récupérer la présence d'un utilisateur
  """
  def get_user_presence(user_id) do
    key = presence_key(user_id)
    
    case RedisConnection.session_command("HGETALL", [key]) do
      {:ok, []} ->
        {:ok, nil} # Utilisateur pas en cache = offline
        
      {:ok, fields} when is_list(fields) ->
        presence = parse_redis_hash(fields)
        {:ok, presence}
        
      {:error, reason} ->
        Logger.error("Failed to get user presence", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer la présence de plusieurs utilisateurs
  """
  def get_users_presence(user_ids) when is_list(user_ids) do
    keys = Enum.map(user_ids, &presence_key/1)
    
    # Utiliser pipeline pour efficacité
    commands = Enum.map(keys, fn key -> ["HGETALL", key] end)
    
    case RedisConnection.pipeline(:session_pool, commands) do
      {:ok, results} ->
        presence_map = 
          user_ids
          |> Enum.zip(results)
          |> Enum.map(fn {user_id, fields} ->
            presence = if fields != [], do: parse_redis_hash(fields), else: nil
            {user_id, presence}
          end)
          |> Enum.into(%{})
        
        {:ok, presence_map}
        
      {:error, reason} ->
        Logger.error("Failed to get users presence", %{
          user_ids_count: length(user_ids),
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer la présence d'un utilisateur (déconnexion)
  """
  def remove_user_presence(user_id) do
    key = presence_key(user_id)
    
    case RedisConnection.session_command("DEL", [key]) do
      {:ok, _count} ->
        Logger.debug("User presence removed", %{user_id: user_id})
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to remove user presence", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  ## Indicateurs de Frappe

  @doc """
  Marquer qu'un utilisateur tape dans une conversation
  """
  def set_typing_indicator(conversation_id, user_id, is_typing \\ true) do
    key = typing_key(conversation_id)
    
    if is_typing do
      typing_data = %{
        user_id: user_id,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      
      commands = [
        ["HSET", key, user_id, Jason.encode!(typing_data)],
        ["EXPIRE", key, @typing_ttl]
      ]
      
      case RedisConnection.pipeline(:session_pool, commands) do
        {:ok, _results} ->
          Logger.debug("Typing indicator set", %{
            conversation_id: conversation_id,
            user_id: user_id
          })
          :ok
          
        {:error, reason} ->
          Logger.error("Failed to set typing indicator", %{
            conversation_id: conversation_id,
            user_id: user_id,
            error: reason
          })
          {:error, reason}
      end
    else
      # Arrêter de taper
      case RedisConnection.session_command("HDEL", [key, user_id]) do
        {:ok, _count} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Récupérer les utilisateurs en train de taper dans une conversation
  """
  def get_typing_indicators(conversation_id) do
    key = typing_key(conversation_id)
    
    case RedisConnection.session_command("HGETALL", [key]) do
      {:ok, []} ->
        {:ok, []}
        
      {:ok, fields} when is_list(fields) ->
        typing_users = 
          fields
          |> Enum.chunk_every(2)
          |> Enum.map(fn [user_id, data_json] ->
            case Jason.decode(data_json) do
              {:ok, data} -> 
                Map.put(data, "user_id", user_id)
              {:error, _} -> 
                %{"user_id" => user_id, "started_at" => nil}
            end
          end)
        
        {:ok, typing_users}
        
      {:error, reason} ->
        Logger.error("Failed to get typing indicators", %{
          conversation_id: conversation_id,
          error: reason
        })
        {:error, reason}
    end
  end

  ## Présence dans les Conversations

  @doc """
  Marquer la présence d'un utilisateur dans une conversation
  """
  def set_conversation_presence(conversation_id, user_id, metadata \\ %{}) do
    key = conversation_presence_key(conversation_id)
    
    presence_data = %{
      user_id: user_id,
      joined_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "active"
    } |> Map.merge(metadata)
    
    commands = [
      ["HSET", key, user_id, Jason.encode!(presence_data)],
      ["EXPIRE", key, @conversation_presence_ttl]
    ]
    
    case RedisConnection.pipeline(:session_pool, commands) do
      {:ok, _results} ->
        Logger.debug("Conversation presence set", %{
          conversation_id: conversation_id,
          user_id: user_id
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to set conversation presence", %{
          conversation_id: conversation_id,
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer tous les utilisateurs présents dans une conversation
  """
  def get_conversation_presence(conversation_id) do
    key = conversation_presence_key(conversation_id)
    
    case RedisConnection.session_command("HGETALL", [key]) do
      {:ok, []} ->
        {:ok, []}
        
      {:ok, fields} when is_list(fields) ->
        present_users = 
          fields
          |> Enum.chunk_every(2)
          |> Enum.map(fn [user_id, data_json] ->
            case Jason.decode(data_json) do
              {:ok, data} -> 
                Map.put(data, "user_id", user_id)
              {:error, _} -> 
                %{"user_id" => user_id}
            end
          end)
        
        {:ok, present_users}
        
      {:error, reason} ->
        Logger.error("Failed to get conversation presence", %{
          conversation_id: conversation_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer la présence d'un utilisateur d'une conversation
  """
  def remove_conversation_presence(conversation_id, user_id) do
    key = conversation_presence_key(conversation_id)
    
    case RedisConnection.session_command("HDEL", [key, user_id]) do
      {:ok, _count} ->
        Logger.debug("Conversation presence removed", %{
          conversation_id: conversation_id,
          user_id: user_id
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to remove conversation presence", %{
          conversation_id: conversation_id,
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  ## Fonctions utilitaires

  defp presence_key(user_id), do: "presence:user:#{user_id}"
  defp typing_key(conversation_id), do: "typing:conversation:#{conversation_id}"
  defp conversation_presence_key(conversation_id), do: "presence:conversation:#{conversation_id}"

  defp flatten_hash(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      value_str = if is_binary(value), do: value, else: Jason.encode!(value)
      [to_string(key), value_str]
    end)
  end

  defp parse_redis_hash([]), do: nil
  defp parse_redis_hash(fields) when is_list(fields) do
    fields
    |> Enum.chunk_every(2)
    |> Enum.map(fn [key, value] ->
      # Essayer de décoder JSON, sinon garder comme string
      parsed_value = case Jason.decode(value) do
        {:ok, decoded} -> decoded
        {:error, _} -> value
      end
      {key, parsed_value}
    end)
    |> Enum.into(%{})
  end
end
