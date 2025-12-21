defmodule Rag.Repo.Migrations.CreateRagChunks do
  use Ecto.Migration

  def change do
    # Enable pgvector extension
    execute("CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector")

    create table(:rag_chunks) do
      add(:content, :text, null: false)
      add(:source, :string)
      # Gemini embedding dimension
      add(:embedding, :vector, size: 768)
      add(:metadata, :map, default: %{})

      timestamps()
    end

    # Create IVFFlat index for approximate nearest neighbor search
    # Use vector_l2_ops for L2 distance (Euclidean)
    create(
      index(:rag_chunks, ["embedding vector_l2_ops"],
        using: :ivfflat,
        name: :rag_chunks_embedding_idx,
        comment: "IVFFlat index for semantic similarity search"
      )
    )

    # Create GIN index for full-text search
    execute(
      """
      CREATE INDEX rag_chunks_content_tsv_idx
      ON rag_chunks
      USING gin(to_tsvector('english', content))
      """,
      "DROP INDEX IF EXISTS rag_chunks_content_tsv_idx"
    )

    # Index on source for filtering
    create(index(:rag_chunks, [:source]))
  end
end
