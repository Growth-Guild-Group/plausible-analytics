# Plausible CE Fork — Sites API Controller

Plausible CE (v2.1.0+) strips the Sites API routes. The EE controller lives in
`extra/` under a proprietary license we cannot use. This guide adds a **new,
clean-room controller** written from scratch in `lib/` (AGPL-licensed code only).

## Prerequisites

- Fork `plausible/analytics` on GitHub
- Clone locally
- Ensure you can build: `MIX_ENV=ce mix release`

## AGPL Obligations

Since we modify AGPL code and run it as a network service, we **must** publish
our forked Plausible source. This obligation applies **only** to the Elixir
application, not to GuildOS. Push the fork to a public GitHub repo.

---

## Step 1: Create the Controller

Create `lib/plausible_web/controllers/api/sites_controller.ex`:

```elixir
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
```

---

## Step 2: Add Routes

Edit `lib/plausible_web/router.ex`. Find the `on_ee do` block that defines the
`/api/v1/sites` scope and add a CE version **outside** that block (or replace it
if you remove the `on_ee` gate entirely).

Add this **after** the Stats API scope and **outside** any `on_ee` block:

```elixir
    # Sites API — CE fork (clean-room implementation)
    scope "/api/v1/sites", PlausibleWeb.Api do
      pipe_through :public_api

      # Read operations — require sites:read:* OR sites:provision:*
      scope assigns: %{api_scope: "sites:provision:*"} do
        pipe_through PlausibleWeb.Plugs.AuthorizePublicAPI

        get "/", SitesController, :index
        post "/", SitesController, :create_site

        scope assigns: %{api_context: :site} do
          get "/:site_id", SitesController, :get_site
          delete "/:site_id", SitesController, :delete_site
        end
      end
    end
```

> **Note:** We use `sites:provision:*` scope for all operations to keep it
> simple. The auth plug (`AuthorizePublicAPI`) already validates this scope
> against the API key.

---

## Step 3: Handle the Billing Feature Gate

The `AuthorizePublicAPI` plug checks `Plausible.Billing.Feature.SitesAPI` for
`sites:*` scopes. In CE, this module may not exist or may deny access.

Check `lib/plausible/billing/feature.ex`. If `SitesAPI` is defined in `extra/`
only, you need to either:

**Option A** — Bypass the feature check for `sites:provision:*` in the auth plug.

In `lib/plausible_web/plugs/authorize_public_api.ex`, find the `verify_by_scope`
function. If it gates on a billing feature for `sites:*` scopes, add a CE-compatible
fallback:

```elixir
# In verify_by_scope/3, add or modify:
defp verify_by_scope(conn, api_key, "sites:" <> _rest = scope) do
  # CE: skip billing feature check, just verify scope string
  if scope in api_key.scopes do
    {:ok, assign(conn, :authorized_scope, scope)}
  else
    {:error, :invalid_scope}
  end
end
```

**Option B** — Define a stub `SitesAPI` feature module in `lib/` that always
returns `:ok`.

---

## Step 4: Build and Deploy

```bash
# Build CE release with our new controller
MIX_ENV=ce mix deps.get
MIX_ENV=ce mix release

# Or build Docker image
docker build --build-arg MIX_ENV=ce -t your-registry/plausible-ce-fork:latest .
```

Deploy the forked image to your hosting (Railway, etc.) replacing the stock
`ghcr.io/plausible/community-edition` image.

---

## Step 5: Verify

```bash
# Create a site
curl -X POST https://your-plausible-host/api/v1/sites \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"domain": "test.example.com", "timezone": "Etc/UTC"}'

# Get a site
curl https://your-plausible-host/api/v1/sites/test.example.com \
  -H "Authorization: Bearer YOUR_API_KEY"

# List sites
curl https://your-plausible-host/api/v1/sites \
  -H "Authorization: Bearer YOUR_API_KEY"

# Delete a site
curl -X DELETE https://your-plausible-host/api/v1/sites/test.example.com \
  -H "Authorization: Bearer YOUR_API_KEY"
```

---

## What This Enables

Once deployed, the GuildOS Plausible adapter at
`src/features/analytics/adapters/plausible.ts` will work as-is — no TypeScript
changes needed. The adapter calls:

- `POST /api/v1/sites` → `SitesController.create_site/2`
- `GET /api/v1/sites/:domain` → `SitesController.get_site/2`
- `DELETE /api/v1/sites/:domain` → `SitesController.delete_site/2`
- `GET /api/v1/sites` → `SitesController.index/2` (used by health check)
