if Code.ensure_loaded?(Ash) do
  defmodule Rag.VectorStore.Ash do
    @moduledoc """
    Ash-resource implementation of `Rag.VectorStore.Store`.

    Wraps any Ash resource with a vector attribute. Reads and writes go through
    Ash actions, so resource policies, multitenancy, calculations, and
    relationships continue to apply.

    ## Usage

        store = %Rag.VectorStore.Ash{
          resource: MyApp.Document.Chunk,
          embedding_attribute: :embedding,
          content_attribute: :content,
          source_attribute: :source,
          metadata_attribute: :metadata
        }

        {:ok, count}   = Rag.VectorStore.Store.insert(store, documents)
        {:ok, results} = Rag.VectorStore.Store.search(store, embedding, limit: 10)

    ## Requirements

    - The configured `resource` must be an Ash resource.
    - For `search/3`, the resource's data layer must support the
      `vector_cosine_distance` expression (e.g. `AshPostgres.DataLayer` with
      the pgvector extension).
    - The resource must define `:create`, `:read`, and `:destroy` actions
      accepting the configured attributes. The defaults from
      `defaults [:create, :read, :update, :destroy]` are sufficient.
    """

    @behaviour Rag.VectorStore.Store

    import Ash.Expr, only: [ref: 1]

    require Ash.Expr
    require Ash.Query

    defstruct [
      :resource,
      :embedding_attribute,
      :content_attribute,
      :source_attribute,
      :metadata_attribute,
      :id_attribute,
      :tenant,
      :actor,
      :domain
    ]

    @type t :: %__MODULE__{
            resource: module(),
            embedding_attribute: atom(),
            content_attribute: atom() | nil,
            source_attribute: atom() | nil,
            metadata_attribute: atom() | nil,
            id_attribute: atom() | nil,
            tenant: any() | nil,
            actor: any() | nil,
            domain: module() | nil
          }

    @default_limit 10
    @default_content_attribute :content

    @doc """
    Create a new Ash store.

    ## Options

    - `:resource` (required) - the Ash resource module that stores chunks
    - `:embedding_attribute` (required) - the resource attribute that stores the vector
    - `:content_attribute` - defaults to `:content`
    - `:source_attribute` - optional
    - `:metadata_attribute` - optional
    - `:id_attribute` - defaults to the resource's primary key
    - `:tenant`, `:actor`, `:domain` - forwarded to every Ash call

    ## Examples

        iex> Rag.VectorStore.Ash.new(resource: MyApp.Chunk, embedding_attribute: :embedding)
        %Rag.VectorStore.Ash{resource: MyApp.Chunk, embedding_attribute: :embedding,
                             content_attribute: :content, source_attribute: nil,
                             metadata_attribute: nil, id_attribute: nil,
                             tenant: nil, actor: nil, domain: nil}
    """
    @spec new(keyword()) :: t()
    def new(opts) do
      %__MODULE__{
        resource: Keyword.fetch!(opts, :resource),
        embedding_attribute: Keyword.fetch!(opts, :embedding_attribute),
        content_attribute: Keyword.get(opts, :content_attribute, @default_content_attribute),
        source_attribute: Keyword.get(opts, :source_attribute),
        metadata_attribute: Keyword.get(opts, :metadata_attribute),
        id_attribute: Keyword.get(opts, :id_attribute),
        tenant: Keyword.get(opts, :tenant),
        actor: Keyword.get(opts, :actor),
        domain: Keyword.get(opts, :domain)
      }
    end

    @impl true
    @spec insert(t(), [Rag.VectorStore.Store.document()], keyword()) ::
            {:ok, non_neg_integer()} | {:error, term()}
    def insert(%__MODULE__{}, [], _opts), do: {:ok, 0}

    def insert(%__MODULE__{} = store, documents, _opts) when is_list(documents) do
      inputs = Enum.map(documents, &document_to_input(store, &1))

      try do
        store.resource
        |> Ash.bulk_create(inputs, :create,
          return_errors?: true,
          tenant: store.tenant,
          actor: store.actor,
          domain: store.domain
        )
        |> case do
          %Ash.BulkResult{status: :success, records: records} ->
            {:ok, length(records || inputs)}

          %Ash.BulkResult{status: :success} = result ->
            {:ok, count_from_result(result, length(inputs))}

          %Ash.BulkResult{errors: errors} ->
            {:error, errors}
        end
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec search(t(), [float()], keyword()) ::
            {:ok, [Rag.VectorStore.Store.result()]} | {:error, term()}
    def search(%__MODULE__{} = store, embedding, opts) when is_list(embedding) do
      limit = Keyword.get(opts, :limit, @default_limit)
      embedding_attr = store.embedding_attribute

      try do
        store.resource
        |> Ash.Query.calculate(
          :_rag_distance,
          :float,
          Ash.Expr.expr(vector_cosine_distance(^ref(embedding_attr), ^embedding))
        )
        |> Ash.Query.sort(asc: :_rag_distance)
        |> Ash.Query.limit(limit)
        |> Ash.read(tenant: store.tenant, actor: store.actor, domain: store.domain)
        |> case do
          {:ok, records} ->
            {:ok, Enum.map(records, &record_to_result(store, &1))}

          {:error, error} ->
            {:error, error}
        end
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec delete(t(), [any()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
    def delete(%__MODULE__{}, [], _opts), do: {:ok, 0}

    def delete(%__MODULE__{} = store, ids, _opts) when is_list(ids) do
      id_attr = id_attribute!(store)

      try do
        store.resource
        |> Ash.Query.filter(^ref(id_attr) in ^ids)
        |> Ash.bulk_destroy(:destroy, %{},
          return_errors?: true,
          strategy: [:stream, :atomic, :atomic_batches],
          tenant: store.tenant,
          actor: store.actor,
          domain: store.domain
        )
        |> case do
          %Ash.BulkResult{status: :success} = result ->
            {:ok, count_from_result(result, length(ids))}

          %Ash.BulkResult{errors: errors} ->
            {:error, errors}
        end
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    @impl true
    @spec get(t(), [any()], keyword()) ::
            {:ok, [Rag.VectorStore.Store.document()]} | {:error, term()}
    def get(%__MODULE__{}, [], _opts), do: {:ok, []}

    def get(%__MODULE__{} = store, ids, _opts) when is_list(ids) do
      id_attr = id_attribute!(store)

      try do
        store.resource
        |> Ash.Query.filter(^ref(id_attr) in ^ids)
        |> Ash.read(tenant: store.tenant, actor: store.actor, domain: store.domain)
        |> case do
          {:ok, records} ->
            {:ok, Enum.map(records, &record_to_document(store, &1))}

          {:error, error} ->
            {:error, error}
        end
      rescue
        error -> {:error, Exception.message(error)}
      end
    end

    defp document_to_input(store, doc) do
      %{}
      |> put_attr(store.content_attribute, Map.get(doc, :content))
      |> put_attr(store.embedding_attribute, Map.get(doc, :embedding))
      |> put_attr(store.source_attribute, Map.get(doc, :source))
      |> put_attr(store.metadata_attribute, Map.get(doc, :metadata) || %{})
      |> put_id(store, doc)
    end

    defp put_attr(input, nil, _value), do: input
    defp put_attr(input, _key, nil), do: input
    defp put_attr(input, key, value), do: Map.put(input, key, value)

    defp put_id(input, store, %{id: id}) when not is_nil(id) do
      Map.put(input, id_attribute!(store), id)
    end

    defp put_id(input, _store, _doc), do: input

    defp record_to_result(store, record) do
      distance = read_distance(record)

      %{
        id: read_attr(record, id_attribute!(store)),
        content: read_attr(record, store.content_attribute || @default_content_attribute),
        score: distance_to_score(distance),
        source: read_attr(record, store.source_attribute),
        metadata: read_attr(record, store.metadata_attribute) || %{}
      }
    end

    defp record_to_document(store, record) do
      %{
        id: read_attr(record, id_attribute!(store)),
        content: read_attr(record, store.content_attribute || @default_content_attribute),
        embedding: read_attr(record, store.embedding_attribute),
        source: read_attr(record, store.source_attribute),
        metadata: read_attr(record, store.metadata_attribute) || %{}
      }
    end

    defp read_attr(_record, nil), do: nil

    defp read_attr(record, key) when is_atom(key) and is_map(record) do
      Map.get(record, key)
    end

    defp read_distance(%{calculations: %{_rag_distance: distance}}) when is_number(distance) do
      distance
    end

    defp read_distance(%{_rag_distance: distance}) when is_number(distance), do: distance
    defp read_distance(_record), do: nil

    # Mirrors `Rag.VectorStore.Pgvector`'s normalization so scores are
    # comparable across backends.
    defp distance_to_score(nil), do: nil
    defp distance_to_score(distance) when is_number(distance), do: 1.0 / (1.0 + distance)

    defp id_attribute!(%__MODULE__{id_attribute: name}) when not is_nil(name), do: name

    defp id_attribute!(%__MODULE__{resource: resource}) do
      [pkey | _] = Ash.Resource.Info.primary_key(resource)
      pkey
    end

    defp count_from_result(%Ash.BulkResult{records: records}, _fallback) when is_list(records),
      do: length(records)

    defp count_from_result(_result, fallback), do: fallback
  end
end
