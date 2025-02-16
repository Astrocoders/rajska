defmodule Rajska.FieldAuthorization do
  @moduledoc """
  Absinthe middleware to ensure field permissions.

  Authorizes Absinthe's object [field](https://hexdocs.pm/absinthe/Absinthe.Schema.Notation.html#field/4) according to the result of the `c:Rajska.Authorization.has_user_access?/3` function, which receives the user role, the `source` object that is resolving the field and the field rule.

  ## Usage

  [Create your Authorization module and add it and FieldAuthorization to your Absinthe.Schema](https://hexdocs.pm/rajska/Rajska.html#module-usage).

  ```elixir
    object :user do
      # Turn on both Object and Field scoping, but if the ObjectScope Phase is not included, this is the same as using `scope_field?`
      meta :scope?, true

      field :name, :string
      field :is_email_public, :boolean

      field :phone, :string, meta: [private: true]
      field :email, :string, meta: [private: & !&1.is_email_public]

      # Can also use custom rules for each field
      field :always_private, :string, meta: [private: true, rule: :private]

      # Can also pass a anonymizer function in case of authentication failure
      field :email_anon, meta: [private: true, anonymizer: &(anonymize_email(&1))]
    end

    object :field_scope_user do
      meta :scope_field?, true

      field :name, :string
      field :phone, :string, meta: [private: true]
    end
  ```

  As seen in the example above, a function can also be passed as value to the meta `:private` key, in order to check if a field is private dynamically, depending of the value of another field.
  """

  @behaviour Absinthe.Middleware

  alias Absinthe.{
    Resolution,
    Type
  }

  def call(resolution, object: %Type.Object{fields: fields} = object, field: field) do
    {private_config, _binding} = fields[field] |> Type.meta(:private) |> Code.eval_quoted()
    field_private? = field_private?(private_config, resolution.source)
    scope? = get_scope!(object)

    default_rule = Rajska.apply_auth_mod(resolution.context, :default_rule)
    rule = Type.meta(fields[field], :rule) || default_rule
    {anonymizer, _binding} = fields[field] |> Type.meta(:anonymizer) |> Code.eval_quoted()

    resolution
    |> Map.get(:context)
    |> authorized?(scope? && field_private?, resolution.source, rule)
    |> put_result(resolution, field, anonymizer)
  end

  defp field_private?(true, _source), do: true
  defp field_private?(private, source) when is_function(private), do: private.(source)
  defp field_private?(_private, _source), do: false

  defp get_scope!(object) do
    scope? = Type.meta(object, :scope?)
    scope_field? = Type.meta(object, :scope_field?)

    case {scope?, scope_field?} do
      {nil, nil} ->
        true

      {nil, scope_field?} ->
        scope_field?

      {scope?, nil} ->
        scope?

      {_, _} ->
        raise "Error in #{inspect(object.identifier)}. If scope_field? is defined, then scope? must not be defined"
    end
  end

  defp authorized?(_context, false, _source, _rule), do: true

  defp authorized?(context, true, source, rule) do
    Rajska.apply_auth_mod(context, :context_user_authorized?, [context, source, rule])
  end

  defp put_result(true, resolution, _field, _), do: resolution

  defp put_result(false, %{context: _context, source: source} = resolution, field, anonymizer)
       when is_function(anonymizer) do
    Resolution.put_result(resolution, anonymizer.(source, field))
  end

  defp put_result(false, %{context: context} = resolution, field, _anonymizer) do
    Resolution.put_result(
      resolution,
      {:error, Rajska.apply_auth_mod(context, :unauthorized_field_message, [resolution, field])}
    )
  end
end
