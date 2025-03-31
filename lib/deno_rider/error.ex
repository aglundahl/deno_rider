defmodule DenoRider.Error do
  @enforce_keys [
    :name
  ]

  @type t :: %__MODULE__{}

  defexception [:message, :name, :value]

  def exception(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message),
      name: Keyword.fetch!(opts, :name),
      value: Keyword.get(opts, :value)
    }
  end

  def message(error) do
    if error.message do
      "#{error.name}: #{error.message}"
    else
      Atom.to_string(error.name)
    end
  end
end
