defmodule Rag.Repo do
  @moduledoc """
  Stub Ecto repository module for testing purposes.

  In production, applications should use their own Ecto.Repo.
  This module provides function signatures that can be mocked with Mimic.
  """

  def all(_query), do: []
  def get(_schema, _id), do: nil
  def insert(_changeset), do: {:error, :not_implemented}
  def insert!(_changeset), do: raise("Not implemented")
  def insert_all(_schema, _entries, _opts \\ []), do: {0, nil}
  def update(_changeset), do: {:error, :not_implemented}
  def update!(_changeset), do: raise("Not implemented")
  def delete(_struct), do: {:error, :not_implemented}
  def delete!(_struct), do: raise("Not implemented")
  def delete_all(_query), do: {0, nil}
end
