defmodule Mix.Tasks.CompileProtos do
  @moduledoc """
  Tâche Mix pour compiler les fichiers protobuf en modules Elixir
  
  Usage:
    mix compile_protos
    
  Cette tâche compile tous les fichiers .proto dans priv/protos/
  et génère les modules Elixir correspondants dans lib/whispr_messaging/grpc/
  """
  
  use Mix.Task

  @shortdoc "Compile les fichiers protobuf"
  
  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Compilation des fichiers protobuf...")
    
    # Créer le répertoire de destination
    output_dir = "lib/whispr_messaging/grpc"
    File.mkdir_p!(output_dir)
    
    # Trouver tous les fichiers .proto
    proto_files = 
      "priv/protos/*.proto"
      |> Path.wildcard()
      |> Enum.sort()
    
    if Enum.empty?(proto_files) do
      Mix.shell().info("Aucun fichier protobuf trouvé dans priv/protos/")
      :ok
    else
      Mix.shell().info("Fichiers protobuf trouvés: #{Enum.join(proto_files, ", ")}")
      
      # Compiler chaque fichier
      Enum.each(proto_files, &compile_proto_file/1)
      
      Mix.shell().info("✅ Compilation protobuf terminée")
      :ok
    end
  end
  
  defp compile_proto_file(proto_file) do
    Mix.shell().info("Compilation de #{proto_file}...")
    
    case :grpcbox_plugin.generate_module(
      String.to_charlist(proto_file),
      [
        {:include_dirs, [~c"priv/protos"]},
        {:output_dir, ~c"lib/whispr_messaging/grpc"},
        {:module_name_suffix, ~c"_pb"},
        {:module_name_prefix, ~c"Elixir.WhisprMessaging.Grpc."}
      ]
    ) do
      :ok ->
        Mix.shell().info("✅ #{proto_file} compilé avec succès")
        
      {:error, reason} ->
        Mix.shell().error("❌ Erreur lors de la compilation de #{proto_file}: #{inspect(reason)}")
        Mix.raise("Échec de la compilation protobuf")
    end
  end
end
