defmodule Rajska.Schema do
  @moduledoc """
  Concatenates Rajska middlewares with Absinthe middlewares and validates Query Authorization configuration.
  """

  alias Absinthe.Middleware
  alias Absinthe.Type.{Field, Object}

  alias Rajska.{
    FieldAuthorization,
    ObjectAuthorization,
    QueryAuthorization
  }

  @modules_to_skip [Absinthe.Phase.Schema.Introspection]

  @spec add_query_authorization(
    [Middleware.spec(), ...],
    Field.t(),
    module()
  ) :: [Middleware.spec(), ...]
  def add_query_authorization(middlewares, %Field{name: query_name, definition: definition_module}, authorization)
  when definition_module not in @modules_to_skip do
    middlewares
    |> Enum.find(&find_middleware/1)
    |> case do
      {{QueryAuthorization, :call}, config} ->
        validate_query_auth_config!(config, authorization, query_name)

      {{Absinthe.Resolution, :call}, _config} ->
        raise "No permission specified for query #{query_name}"
    end

    middlewares
  end

  def add_query_authorization(middlewares, _field, _authorization), do: middlewares

  def find_middleware({{QueryAuthorization, :call}, _config}), do: true
  def find_middleware({{Absinthe.Resolution, :call}, _config}), do: true
  def find_middleware(_), do: false

  @spec add_object_authorization([Middleware.spec(), ...]) :: [Middleware.spec(), ...]
  def add_object_authorization(middlewares) do
    middlewares
    |> Enum.reduce([], fn
      {{QueryAuthorization, :call}, _config} = query_authorization, new_middlewares ->
        [ObjectAuthorization, query_authorization] ++ new_middlewares

      {{Absinthe.Resolution, :call}, _config} = resolution, new_middlewares ->
        add_object_authorization_if_not_yet_present(resolution, new_middlewares)

      middleware, new_middlewares ->
        [middleware | new_middlewares]
    end)
    |> Enum.reverse()
  end

  defp add_object_authorization_if_not_yet_present(resolution, new_middlewares) do
    case Enum.member?(new_middlewares, ObjectAuthorization) do
      true -> [resolution | new_middlewares]
      false -> [resolution, ObjectAuthorization] ++ new_middlewares
    end
  end

  @spec add_field_authorization(
    [Middleware.spec(), ...],
    Field.t(),
    Object.t()
  ) :: [Middleware.spec(), ...]
  def add_field_authorization(middleware, %Field{identifier: field}, object) do
    [{{FieldAuthorization, :call}, object: object, field: field} | middleware]
  end

  @spec validate_query_auth_config!(
    [
      permit: atom(),
      scope: false | module(),
      args: %{} | [] | atom(),
      optional: false | true,
      rule: atom()
    ],
    module(),
    String.t()
  ) :: :ok | Exception.t()

  def validate_query_auth_config!(config, authorization, query_name) do
    permit = Keyword.get(config, :permit)
    scope = Keyword.get(config, :scope)
    args = Keyword.get(config, :args, :id)
    rule = Keyword.get(config, :rule, :default_rule)
    optional = Keyword.get(config, :optional, false)

    try do
      validate_presence!(permit, :permit)
      validate_boolean!(optional, :optional)
      validate_atom!(rule, :rule)

      validate_scope!(scope, permit, authorization)
      validate_args!(args)
    rescue
      e in RuntimeError -> reraise "Query #{query_name} is configured incorrectly, #{e.message}", __STACKTRACE__
    end
  end

  defp validate_presence!(nil, option), do: raise "#{inspect(option)} option must be present."
  defp validate_presence!(_value, _option), do: :ok

  defp validate_boolean!(value, _option) when is_boolean(value), do: :ok
  defp validate_boolean!(_value, option), do: raise "#{inspect(option)} option must be a boolean."

  defp validate_atom!(value, _option) when is_atom(value), do: :ok
  defp validate_atom!(_value, option), do: raise "#{inspect(option)} option must be an atom."

  defp validate_scope!(nil, role, authorization) do
    unless Enum.member?(authorization.not_scoped_roles(), role),
      do: raise ":scope option must be present for role #{inspect(role)}."
  end

  defp validate_scope!(false, _role, _authorization), do: :ok

  defp validate_scope!(scope, _role, _authorization) when is_atom(scope) do
    struct!(scope)
  rescue
    UndefinedFunctionError -> reraise ":scope option #{inspect(scope)} is not a struct.", __STACKTRACE__
  end

  defp validate_args!(args) when is_map(args) do
    Enum.each(args, fn
      {field, value} when is_atom(field) and is_atom(value) -> :ok
      {field, values} when is_atom(field) and is_list(values) -> validate_list_of_atoms_or_function!(values)
      field_value -> raise "the following args option is invalid: #{inspect(field_value)}. Since the provided args is a map, you should provide an atom key and an atom or list of atoms value."
    end)
  end

  defp validate_args!(args) when is_list(args), do: validate_list_of_atoms!(args)
  defp validate_args!(args) when is_atom(args), do: :ok
  defp validate_args!(args), do: raise "the following args option is invalid: #{inspect(args)}"

  defp validate_list_of_atoms!(args) do
    Enum.each(args, fn
      arg when is_atom(arg) -> :ok
      arg -> raise "the following args option is invalid: #{inspect(args)}. Expected a list of atoms, but found #{inspect(arg)}"
    end)
  end

  defp validate_list_of_atoms_or_function!(args) do
    Enum.each(args, fn
      arg when is_atom(arg) or is_function(arg) -> :ok
      arg -> raise "the following args option is invalid: #{inspect(args)}. Expected a list of atoms or functions, but found #{inspect(arg)}"
    end)
  end
end
