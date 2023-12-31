# SPDX-License-Identifier: AGPL-3.0-only
if Bonfire.Common.Extend.module_enabled?(Bonfire.API.GraphQL) do
  defmodule Bonfire.Classify.GraphQL.CategoryResolver do
    @moduledoc "GraphQL tag/category queries"

    alias Bonfire.Common.Utils
    import Bonfire.Common.Config, only: [repo: 0]

    alias Bonfire.API.GraphQL

    alias Bonfire.API.GraphQL.Page
    alias Bonfire.API.GraphQL.FetchFields
    alias Bonfire.API.GraphQL.FetchPage
    # FetchPages,
    alias Bonfire.API.GraphQL.ResolveField
    alias Bonfire.API.GraphQL.ResolveFields
    # ResolvePage,
    alias Bonfire.API.GraphQL.ResolvePages
    alias Bonfire.API.GraphQL.ResolveRootPage

    alias Bonfire.Classify.Category
    alias Bonfire.Classify.Categories

    def cursor(), do: &[&1.id]
    def test_cursor(), do: &[&1["id"]]

    def categories(page_opts, info) do
      # IO.inspect(categories_page_opts: data_filters)
      ResolveRootPage.run(%ResolveRootPage{
        module: __MODULE__,
        fetcher: :fetch_categories,
        page_opts: page_opts,
        info: info,
        # popularity
        cursor_validators: [
          &(is_integer(&1) and &1 >= 0),
          &Needle.ULID.cast/1
        ]
      })
    end

    def fetch_categories(page_opts, info) do
      # IO.inspect(fetch_categories_page_opts: Map.get(info, :data_filters))
      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor,
        page_opts: page_opts,
        # base_filters: [user: GraphQL.current_user(info)],
        data_filters:
          ValueFlows.Util.GraphQL.fetch_data_filters(
            [:default, page: [desc: [id: page_opts]]],
            info
          )
      })
    end

    def categories_toplevel(page_opts, info) do
      ResolveRootPage.run(%ResolveRootPage{
        module: __MODULE__,
        fetcher: :fetch_categories_toplevel,
        page_opts: page_opts,
        info: info,
        # popularity
        cursor_validators: [
          &(is_integer(&1) and &1 >= 0),
          &Needle.ULID.cast/1
        ]
      })
    end

    def fetch_categories_toplevel(page_opts, _info) do
      # TODO: boundaries queries
      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor,
        page_opts: page_opts,
        # base_filters: [user: GraphQL.current_user(info)],
        data_filters: [:default, :toplevel, page: [desc: [id: page_opts]]]
      })
    end

    def category(%{category_id: id}, info) do
      ResolveField.run(%ResolveField{
        module: __MODULE__,
        fetcher: :fetch_category,
        context: id,
        info: info
      })
    end

    ## fetchers

    def fetch_category(info, id) do
      Categories.get(id, current_user: GraphQL.current_user(info))
    end

    def parent_category(%{parent_category: parent_category}, _, info) do
      ResolveFields.run(%ResolveFields{
        module: __MODULE__,
        fetcher: :fetch_parent_category,
        context: Enums.id(parent_category),
        info: info
      })
    end

    def parent_category(%{tree: %{parent: parent_category}}, _, info) do
      ResolveFields.run(%ResolveFields{
        module: __MODULE__,
        fetcher: :fetch_parent_category,
        context: Enums.id(parent_category),
        info: info
      })
    end

    def fetch_parent_category(_, ids) do
      FetchFields.run(%FetchFields{
        queries: Category.Queries,
        query: Category,
        group_fn: & &1.id,
        filters: [:default, id: ids]
      })
    end

    @doc "List child categories"
    def category_children(%{id: id}, %{} = page_opts, info) do
      ResolvePages.run(%ResolvePages{
        module: __MODULE__,
        fetcher: :fetch_categories_children,
        context: id,
        page_opts: page_opts,
        info: info
      })
    end

    def fetch_categories_children(page_opts, info, id) do
      user = GraphQL.current_user(info)

      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor(:followers),
        page_opts: page_opts,
        base_filters: [parent_category: id, user: user],
        data_filters: [:default, page: [desc: [id: page_opts]]]
      })
    end

    @doc """
    Retrieves an Page of categorys according to various filters

    Used by:
    * GraphQL resolver single-parent resolution
    """
    def page(
          cursor_fn,
          page_opts,
          base_filters \\ [],
          data_filters \\ [],
          count_filters \\ []
        )

    def page(
          cursor_fn,
          %{} = page_opts,
          base_filters,
          data_filters,
          count_filters
        ) do
      base_q = Queries.query(Category, base_filters)
      data_q = Queries.filter(base_q, data_filters)
      count_q = Queries.filter(base_q, count_filters)

      with {:ok, [data, counts]} <-
             repo().transact_many(all: data_q, count: count_q) do
        {:ok, Page.new(data, counts, cursor_fn, page_opts)}
      end
    end

    @doc """
    Retrieves an Pages of categorys according to various filters

    Used by:
    * GraphQL resolver bulk resolution
    """
    def pages(
          cursor_fn,
          group_fn,
          page_opts,
          base_filters \\ [],
          data_filters \\ [],
          count_filters \\ []
        )

    def pages(
          cursor_fn,
          group_fn,
          page_opts,
          base_filters,
          data_filters,
          count_filters
        ) do
      Bonfire.API.GraphQL.Pagination.pages(
        Queries,
        Category,
        cursor_fn,
        group_fn,
        page_opts,
        base_filters,
        data_filters,
        count_filters
      )
    end

    #### MUTATIONS

    def create_category(attrs, info) do
      repo().transact_with(fn ->
        attrs = Map.merge(attrs, %{is_public: true})

        with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
             {:ok, category} <- Bonfire.Classify.Categories.create(user, attrs) do
          {:ok, category}
        end
      end)
    end

    ### decorators

    def name(%{profile: %{name: name}}, _, _info) when not is_nil(name) do
      {:ok, name}
    end

    def name(%{name: name}, _, _info) when not is_nil(name) do
      {:ok, name}
    end

    # def name(%{name: name, context_id: context_id}, _, _info)
    #     when is_nil(name) and not is_nil(context_id) do

    #   # TODO: optimise so it doesn't repeat these queries (for context and summary fields)
    #   with {:ok, context} <- Bonfire.Common.Needles.get(id: context_id) do
    #     name = if Map.has_key?(context, :name), do: context.name
    #     {:ok, name}
    #   end
    # end

    def name(_, _, _) do
      {:ok, nil}
    end

    def summary(%{profile: %{summary: summary}}, _, _info)
        when not is_nil(summary) do
      {:ok, summary}
    end

    def summary(%{summary: summary}, _, _info) when not is_nil(summary) do
      {:ok, summary}
    end

    # def summary(%{summary: summary, context_id: context_id}, _, _info)
    #     when is_nil(summary) and not is_nil(context_id) do

    #   # TODO: optimise so it doesn't repeat these queries (for context and summary fields)
    #   with {:ok, context} <- Bonfire.Common.Needles.get(context_id) do
    #     summary = if Map.has_key?(context, :summary), do: context.summary
    #     {:ok, summary}
    #   end
    # end

    def summary(_, _, _) do
      {:ok, nil}
    end

    # def search_category(%{query: id}, info) do
    #   {:ok, Simulate.long_node_list(&Simulate.tag/0)}
    #   |> GraphQL.response(info)
    # end

    def update_category(%{category_id: id} = changes, info) do
      repo().transact_with(fn ->
        with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
             {:ok, category} <- category(%{category_id: id}, info),
             #  :ok <- ensure_update_allowed(user, category),
             {:ok, c} <- Categories.update(user, category, changes) do
          {:ok, c}
        end
      end)
    end

    def ensure_update_allowed(user, c) do
      if Classify.ensure_update_allowed(user, c) do
        :ok
      else
        GraphQL.not_permitted("to update this")
      end
    end

    # def delete_category(%{id: id}, info) do
    #   with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
    #        {:ok, c} <- category(%{id: id}, info),
    #        :ok <- Classify.ensure_delete_allowed(user, c),
    #        {:ok, c} <- Categories.soft_delete(c, user) do
    #     {:ok, true}
    #   end
    # end
  end
end
