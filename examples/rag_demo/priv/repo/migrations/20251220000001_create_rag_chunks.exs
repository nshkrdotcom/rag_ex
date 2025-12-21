defmodule RagDemo.Repo.Migrations.CreateRagChunks do
  use Ecto.Migration

  def up do
    # Enable pgvector extension
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:rag_chunks) do
      add(:content, :text, null: false)
      add(:source, :string)
      add(:embedding, :vector, size: 768)
      add(:metadata, :map, default: %{})

      timestamps()
    end

    # Create IVFFlat index for fast approximate nearest neighbor search
    # Note: For production with many rows, tune 'lists' parameter
    execute("""
    CREATE INDEX rag_chunks_embedding_idx
    ON rag_chunks
    USING ivfflat (embedding vector_l2_ops)
    WITH (lists = 100)
    """)

    # Create GIN index for full-text search
    execute("""
    CREATE INDEX rag_chunks_content_search_idx
    ON rag_chunks
    USING gin (to_tsvector('english', content))
    """)

    # Index on source for filtering
    create(index(:rag_chunks, [:source]))
  end

  def down do
    drop(table(:rag_chunks))
  end
end
