defmodule Rag.GraphStoreTest.MockRepo do
  @moduledoc """
  Mock Ecto repository for GraphStore tests.

  This module provides stub implementations of Ecto.Repo callbacks
  that can be mocked using Mimic in tests.
  """

  def insert(_changeset), do: {:ok, %{}}
  def update(_changeset), do: {:ok, %{}}
  def get(_schema, _id), do: nil
  def all(_query), do: []
end
