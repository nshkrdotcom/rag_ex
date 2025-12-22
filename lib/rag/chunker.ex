defmodule Rag.Chunker do
  @moduledoc """
  Behaviour for text chunking strategies.

  Chunkers split text into smaller pieces suitable for embedding and retrieval.
  Each chunk includes byte positions for source reconstruction.
  """

  alias Rag.Chunker.Chunk

  @type t :: struct()

  @doc """
  Split text into chunks.

  Returns a list of `Rag.Chunker.Chunk` structs.
  """
  @callback chunk(chunker :: t(), text :: String.t(), opts :: keyword()) :: [Chunk.t()]

  @doc """
  Returns default options for this chunker.
  """
  @callback default_opts() :: keyword()

  @optional_callbacks default_opts: 0

  @doc """
  Dispatch to the chunker implementation.
  """
  @spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
  def chunk(%module{} = chunker, text, opts \\ []) when is_binary(text) do
    defaults =
      if function_exported?(module, :default_opts, 0) do
        module.default_opts()
      else
        []
      end

    struct_opts =
      chunker
      |> Map.from_struct()
      |> Enum.into([])

    merged_opts =
      defaults
      |> Keyword.merge(struct_opts)
      |> Keyword.merge(opts)

    module.chunk(chunker, text, merged_opts)
  end

  @doc """
  Chunk an ingestion map, adding chunks to the result.

  Expects input map with a `:document` key containing text.
  Returns a map with `:chunks` added.
  """
  @spec chunk_ingestion(t(), map(), keyword()) :: map()
  def chunk_ingestion(%_module{} = chunker, %{document: text} = ingestion, opts \\ [])
      when is_binary(text) do
    chunks = chunk(chunker, text, opts)
    Map.put(ingestion, :chunks, chunks)
  end
end
