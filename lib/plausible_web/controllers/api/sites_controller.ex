defmodule PlausibleWeb.Api.SitesController do
  @moduledoc """
  Minimal Sites API for CE — create, get, list, delete sites.
  Written from scratch (no EE code). Licensed under AGPL-3.0.
  """
  use PlausibleWeb, :controller
  use Plausible.Repo

  alias Plausible.Sites
  alias Plausible.Site

  # POST /api/v1/sites
  def create_site(conn, params) do
    user = conn.assigns.current_user
    team = conn.assigns[:current_team]

    case Sites.create(user, params, team) do
      {:ok, %{site: site}} ->
        conn
        |> put_status(:ok)
        |> json(%{
          domain: site.domain,
          timezone: site.timezone
        })

      {:error, {:over_limit, _limit}} ->
        conn
        |> put_status(:payment_required)
        |> json(%{error: "Site limit reached"})

      {:error, :permission_denied} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Permission denied"})

      {:error, _, %Ecto.Changeset{} = changeset, _} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Validation failed", details: errors})

      {:error, _, message, _} when is_binary(message) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})

      _ ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create site"})
    end
  end

  # GET /api/v1/sites/:site_id
  def get_site(conn, %{"site_id" => site_id}) do
    user = conn.assigns.current_user

    case Sites.get_for_user(user, site_id, roles: [:owner, :admin, :editor, :viewer]) do
      %Site{} = site ->
        conn
        |> put_status(:ok)
        |> json(%{
          domain: site.domain,
          timezone: site.timezone
        })

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Site could not be found"})
    end
  end

  # GET /api/v1/sites
  def index(conn, params) do
    user = conn.assigns.current_user
    team = conn.assigns[:current_team]

    page = to_integer(params["page"], 1)
    per_page = to_integer(params["per_page"], 100) |> min(1000)

    query = Sites.for_user_query(user, team)

    sites =
      query
      |> Ecto.Query.limit(^per_page)
      |> Ecto.Query.offset(^((page - 1) * per_page))
      |> Repo.all()

    total = Repo.aggregate(query, :count, :id)

    conn
    |> put_status(:ok)
    |> json(%{
      sites: Enum.map(sites, &%{domain: &1.domain, timezone: &1.timezone}),
      meta: %{
        total: total,
        page: page,
        per_page: per_page,
        total_pages: ceil(total / per_page)
      }
    })
  end

  # DELETE /api/v1/sites/:site_id
  def delete_site(conn, %{"site_id" => site_id}) do
    user = conn.assigns.current_user

    case Sites.get_for_user(user, site_id, roles: [:owner]) do
      %Site{} = site ->
        Plausible.Site.Removal.run(site)

        conn
        |> put_status(:ok)
        |> json(%{deleted: true})

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Site could not be found or you do not have permission to delete it"})
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp to_integer(nil, default), do: default
  defp to_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end
  defp to_integer(val, _default) when is_integer(val) and val > 0, do: val
  defp to_integer(_, default), do: default
end
