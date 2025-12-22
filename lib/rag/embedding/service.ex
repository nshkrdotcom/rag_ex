if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Rag.Embedding.Service do
    @moduledoc """
    GenServer-based embedding service for batch processing.

    This service manages embedding generation using the Gemini provider
    (the only provider with embedding support). It handles batching,
    statistics tracking, and integration with the VectorStore.

    ## Usage

        # Start the service
        {:ok, pid} = Service.start_link(batch_size: 100)

        # Embed a single text
        {:ok, embedding} = Service.embed_text(pid, "Hello world")

        # Embed multiple texts
        {:ok, embeddings} = Service.embed_texts(pid, ["text1", "text2"])

        # Embed chunks and add embeddings
        {:ok, chunks_with_embeddings} = Service.embed_chunks(pid, chunks)

    ## Configuration

    - `:batch_size` - Maximum texts per embedding request (default: 100)
    - `:provider` - Provider module to use (default: Rag.Ai.Gemini)

    """

    use GenServer

    alias Rag.Ai.Capabilities
    alias Rag.Ai.Gemini
    alias Rag.VectorStore

    @default_batch_size 100

    defstruct [
      :provider,
      :provider_instance,
      :batch_size,
      :stats
    ]

    @type t :: %__MODULE__{
            provider: module(),
            provider_instance: struct(),
            batch_size: pos_integer(),
            stats: map()
          }

    # Client API

    @doc """
    Start the embedding service.

    ## Options

    - `:name` - Optional process name
    - `:batch_size` - Maximum texts per batch (default: 100)
    - `:provider` - Provider module (default: Rag.Ai.Gemini)

    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) do
      {name, opts} = Keyword.pop(opts, :name)
      gen_opts = if name, do: [name: name], else: []
      GenServer.start_link(__MODULE__, opts, gen_opts)
    end

    @doc """
    Generate embedding for a single text.

    ## Examples

        iex> Service.embed_text(pid, "Hello world")
        {:ok, [0.1, 0.2, ...]}

    """
    @spec embed_text(GenServer.server(), String.t()) :: {:ok, [float()]} | {:error, term()}
    def embed_text(server, text) do
      case embed_texts(server, [text]) do
        {:ok, [embedding]} -> {:ok, embedding}
        {:error, _} = error -> error
      end
    end

    @doc """
    Generate embeddings for multiple texts.

    Automatically batches large requests according to batch_size.

    ## Examples

        iex> Service.embed_texts(pid, ["Hello", "World"])
        {:ok, [[0.1, ...], [0.2, ...]]}

    """
    @spec embed_texts(GenServer.server(), [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
    def embed_texts(server, texts) when is_list(texts) do
      GenServer.call(server, {:embed_texts, texts}, :infinity)
    end

    @doc """
    Embed chunks and add embeddings to them.

    Extracts content from each chunk, generates embeddings,
    and returns chunks with embeddings attached.

    ## Examples

        iex> chunks = [%Chunk{content: "Hello"}, %Chunk{content: "World"}]
        iex> Service.embed_chunks(pid, chunks)
        {:ok, [%Chunk{content: "Hello", embedding: [...]}, ...]}

    """
    @spec embed_chunks(GenServer.server(), [VectorStore.Chunk.t()]) ::
            {:ok, [VectorStore.Chunk.t()]} | {:error, term()}
    def embed_chunks(server, chunks) when is_list(chunks) do
      GenServer.call(server, {:embed_chunks, chunks}, :infinity)
    end

    @doc """
    Embed chunks and prepare for database insertion.

    Similar to `embed_chunks/2` but converts chunks to maps
    ready for Ecto insert.

    """
    @spec embed_and_prepare(GenServer.server(), [VectorStore.Chunk.t()]) ::
            {:ok, [map()]} | {:error, term()}
    def embed_and_prepare(server, chunks) do
      case embed_chunks(server, chunks) do
        {:ok, embedded_chunks} ->
          prepared = Enum.map(embedded_chunks, &VectorStore.prepare_for_insert/1)
          {:ok, prepared}

        {:error, _} = error ->
          error
      end
    end

    @doc """
    Get embedding service statistics.

    Returns counts of texts embedded, batches processed, and errors.

    """
    @spec get_stats(GenServer.server()) :: map()
    def get_stats(server) do
      GenServer.call(server, :get_stats)
    end

    # Server Callbacks

    @impl true
    def init(opts) do
      provider = Keyword.get(opts, :provider, Gemini)
      provider_module = resolve_provider(provider)
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
      provider_instance = provider_module.new(%{})

      state = %__MODULE__{
        provider: provider_module,
        provider_instance: provider_instance,
        batch_size: batch_size,
        stats: %{
          texts_embedded: 0,
          batches_processed: 0,
          errors: 0
        }
      }

      {:ok, state}
    end

    @impl true
    def handle_call({:embed_texts, texts}, _from, state) do
      case do_embed_texts(texts, state) do
        {:ok, embeddings, new_state} ->
          {:reply, {:ok, embeddings}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    end

    @impl true
    def handle_call({:embed_chunks, []}, _from, state) do
      {:reply, {:ok, []}, state}
    end

    @impl true
    def handle_call({:embed_chunks, chunks}, _from, state) do
      texts = Enum.map(chunks, & &1.content)

      case do_embed_texts(texts, state) do
        {:ok, embeddings, new_state} ->
          embedded_chunks = VectorStore.add_embeddings(chunks, embeddings)
          {:reply, {:ok, embedded_chunks}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    end

    @impl true
    def handle_call(:get_stats, _from, state) do
      {:reply, state.stats, state}
    end

    # Private functions

    defp do_embed_texts(texts, state) do
      batches = Enum.chunk_every(texts, state.batch_size)

      result =
        Enum.reduce_while(batches, {:ok, [], state}, fn batch, {:ok, acc, state} ->
          case embed_batch(batch, state) do
            {:ok, embeddings, new_state} ->
              {:cont, {:ok, acc ++ embeddings, new_state}}

            {:error, reason, new_state} ->
              {:halt, {:error, reason, new_state}}
          end
        end)

      case result do
        {:ok, embeddings, final_state} ->
          {:ok, embeddings, final_state}

        {:error, reason, final_state} ->
          {:error, reason, final_state}
      end
    end

    # Resolve provider atom to module, or pass through if already a module
    defp resolve_provider(provider) when is_atom(provider) do
      case Capabilities.get(provider) do
        # Assume it's already a module
        nil -> provider
        caps -> caps.module
      end
    end

    defp embed_batch(texts, state) do
      result = state.provider.generate_embeddings(state.provider_instance, texts, [])

      case result do
        {:ok, embeddings} ->
          new_stats = %{
            state.stats
            | texts_embedded: state.stats.texts_embedded + length(texts),
              batches_processed: state.stats.batches_processed + 1
          }

          {:ok, embeddings, %{state | stats: new_stats}}

        {:error, reason} ->
          new_stats = %{state.stats | errors: state.stats.errors + 1}
          {:error, reason, %{state | stats: new_stats}}
      end
    end
  end
end
