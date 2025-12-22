defmodule Rag.Chunker.FormatAware do
  @moduledoc """
  Format-aware chunking using TextChunker.

  Provides intelligent splitting for code and markup formats using
  language-specific separators (function definitions, class declarations,
  heading levels, etc.).

  ## Options

  - `format` - Document format (default: `:plaintext`)
  - `chunk_size` - Maximum chunk size in code points (default: 2000)
  - `chunk_overlap` - Overlap between chunks (default: 200)
  - `size_fn` - Custom size function `(String.t() -> integer())` (default: nil)
  """

  @behaviour Rag.Chunker

  alias Rag.Chunker.Chunk

  @type t :: %__MODULE__{
          format: atom(),
          chunk_size: pos_integer(),
          chunk_overlap: non_neg_integer(),
          size_fn: (String.t() -> non_neg_integer()) | nil
        }

  defstruct format: :plaintext,
            chunk_size: 2000,
            chunk_overlap: 200,
            size_fn: nil

  @doc "Returns default options for the format-aware chunker."
  @impl true
  @spec default_opts() :: keyword()
  def default_opts do
    [format: :plaintext, chunk_size: 2000, chunk_overlap: 200]
  end

  @doc "Split text into format-aware chunks using TextChunker."
  @impl true
  @spec chunk(t(), String.t(), keyword()) :: [Chunk.t()]
  def chunk(%__MODULE__{} = chunker, text, opts) when is_binary(text) do
    unless Code.ensure_loaded?(TextChunker) do
      raise """
      FormatAware chunker requires TextChunker.
      Add to your mix.exs deps:

          {:text_chunker, "~> 0.5.2"}
      """
    end

    format = opts[:format] || chunker.format
    chunk_size = opts[:chunk_size] || chunker.chunk_size
    chunk_overlap = opts[:chunk_overlap] || chunker.chunk_overlap
    size_fn = opts[:size_fn] || chunker.size_fn

    if text == "" do
      [
        Chunk.new(%{
          content: "",
          start_byte: 0,
          end_byte: 0,
          index: 0,
          metadata: %{chunker: :format_aware, format: format}
        })
      ]
    else
      tc_opts = [
        format: format,
        chunk_size: chunk_size,
        chunk_overlap: chunk_overlap
      ]

      tc_opts =
        if size_fn do
          Keyword.put(tc_opts, :get_chunk_size, size_fn)
        else
          tc_opts
        end

      case TextChunker.split(text, tc_opts) do
        {:error, message} ->
          raise ArgumentError, "TextChunker error: #{message}"

        chunks ->
          chunks
          |> Enum.with_index()
          |> Enum.map(fn {tc_chunk, index} ->
            Chunk.new(%{
              content: tc_chunk.text,
              start_byte: tc_chunk.start_byte,
              end_byte: tc_chunk.end_byte,
              index: index,
              metadata: %{
                chunker: :format_aware,
                format: format
              }
            })
          end)
      end
    end
  end
end
