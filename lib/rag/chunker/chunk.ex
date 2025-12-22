defmodule Rag.Chunker.Chunk do
  @moduledoc """
  Represents a chunk of text with position information.

  ## Fields

  - `content` - The text content of the chunk
  - `start_byte` - Byte offset where chunk begins in source text
  - `end_byte` - Byte offset where chunk ends in source text
  - `index` - Sequential index (0-based) among sibling chunks
  - `metadata` - Additional information (chunker type, hierarchy level, etc.)
  """

  @type t :: %__MODULE__{
          content: String.t(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          index: non_neg_integer(),
          metadata: map()
        }

  @enforce_keys [:content, :start_byte, :end_byte, :index]
  defstruct [
    :content,
    :start_byte,
    :end_byte,
    :index,
    metadata: %{}
  ]

  @doc """
  Create a new chunk from attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    required_keys = [:content, :start_byte, :end_byte, :index]
    Enum.each(required_keys, &Map.fetch!(attrs, &1))

    struct!(__MODULE__, attrs)
  end

  @doc """
  Extract the chunk's content from the original text using byte positions.
  """
  @spec extract_from_source(t(), String.t()) :: binary()
  def extract_from_source(%__MODULE__{start_byte: s, end_byte: e}, source_text)
      when is_binary(source_text) do
    binary_part(source_text, s, e - s)
  end

  @doc """
  Check if chunk positions correctly match the content.
  """
  @spec valid?(t(), String.t()) :: boolean()
  def valid?(%__MODULE__{content: content, start_byte: s, end_byte: e}, source_text)
      when is_binary(source_text) do
    byte_size(content) == e - s and
      binary_part(source_text, s, e - s) == content
  end
end
