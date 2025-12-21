defmodule Rag.VectorStore.Store do
  @moduledoc """
  Behaviour for vector store backends.

  This behaviour defines the interface for different vector storage
  implementations (pgvector, Pinecone, Qdrant, etc.).

  ## Implementing a Custom Store

      defmodule MyApp.CustomVectorStore do
        @behaviour Rag.VectorStore.Store

        defstruct [:connection]

        @impl true
        def insert(store, documents, opts) do
          # Insert documents with embeddings
          {:ok, count}
        end

        @impl true
        def search(store, embedding, opts) do
          # Search by embedding similarity
          {:ok, results}
        end

        @impl true
        def delete(store, ids, opts) do
          # Delete by IDs
          {:ok, count}
        end

        @impl true
        def get(store, ids, opts) do
          # Get by IDs
          {:ok, documents}
        end
      end

  ## Available Implementations

  - `Rag.VectorStore.Pgvector` - PostgreSQL with pgvector extension

  """

  @type embedding :: [float()]
  @type document :: %{
          id: any() | nil,
          content: String.t(),
          embedding: embedding(),
          source: String.t() | nil,
          metadata: map()
        }
  @type result :: %{
          id: any(),
          content: String.t(),
          score: float(),
          source: String.t() | nil,
          metadata: map()
        }

  @doc """
  Insert documents with embeddings into the store.

  ## Parameters

  - `store` - The store struct
  - `documents` - List of documents with embeddings
  - `opts` - Options specific to the implementation

  ## Returns

  - `{:ok, count}` - Number of documents inserted
  - `{:error, reason}` - Error during insertion
  """
  @callback insert(store :: struct(), documents :: [document()], opts :: keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Search for similar documents by embedding.

  ## Parameters

  - `store` - The store struct
  - `embedding` - Query embedding vector
  - `opts` - Options including `:limit`

  ## Returns

  - `{:ok, [result]}` - List of results with similarity scores
  - `{:error, reason}` - Error during search
  """
  @callback search(store :: struct(), embedding :: embedding(), opts :: keyword()) ::
              {:ok, [result()]} | {:error, term()}

  @doc """
  Delete documents by IDs.

  ## Parameters

  - `store` - The store struct
  - `ids` - List of document IDs to delete
  - `opts` - Options specific to the implementation

  ## Returns

  - `{:ok, count}` - Number of documents deleted
  - `{:error, reason}` - Error during deletion
  """
  @callback delete(store :: struct(), ids :: [any()], opts :: keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Get documents by IDs.

  ## Parameters

  - `store` - The store struct
  - `ids` - List of document IDs to retrieve
  - `opts` - Options specific to the implementation

  ## Returns

  - `{:ok, [document]}` - List of documents
  - `{:error, reason}` - Error during retrieval
  """
  @callback get(store :: struct(), ids :: [any()], opts :: keyword()) ::
              {:ok, [document()]} | {:error, term()}

  # Convenience dispatch functions

  @doc """
  Insert documents into the store.
  """
  @spec insert(struct(), [document()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert(%module{} = store, documents, opts \\ []) do
    module.insert(store, documents, opts)
  end

  @doc """
  Search the store by embedding.
  """
  @spec search(struct(), embedding(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def search(%module{} = store, embedding, opts \\ []) do
    module.search(store, embedding, opts)
  end

  @doc """
  Delete documents from the store.
  """
  @spec delete(struct(), [any()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete(%module{} = store, ids, opts \\ []) do
    module.delete(store, ids, opts)
  end

  @doc """
  Get documents from the store by IDs.
  """
  @spec get(struct(), [any()], keyword()) :: {:ok, [document()]} | {:error, term()}
  def get(%module{} = store, ids, opts \\ []) do
    module.get(store, ids, opts)
  end
end
