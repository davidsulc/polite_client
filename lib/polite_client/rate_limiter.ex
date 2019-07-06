defmodule PoliteClient.RateLimiter do
  alias PoliteClient.ResponseMeta

  @min_delay 1_000
  @max_delay 120_000

  @type state :: %{
          limiter: limiter(),
          internal_state: term(),
          current_delay: non_neg_integer(),
          min_delay: non_neg_integer(),
          max_delay: non_neg_integer()
        }

  @type internal_state :: term()

  @type limiter() ::
          (internal_state :: internal_state(), response_meta :: ResponseMeta.t() ->
             {next_request_delay :: non_neg_integer(), new_internal_state :: internal_state()})

  # TODO validations

  @spec to_config(:default) :: {:ok, state()}
  def to_config(:default), do: to_config({:constant, @min_delay})

  def to_config({tag, arg}) when is_atom(tag), do: to_config({tag, arg, []})

  @spec to_config({atom() | limiter(), term(), Keyword.t()}) :: {:ok, state()}

  def to_config({:constant, delay, opts}) do
    opts =
      opts
      |> Keyword.put_new(:min_delay, delay)
      |> Keyword.put_new(:max_delay, delay)

    to_config(fn nil, _response_meta -> {delay, nil} end, nil, opts)
  end

  def to_config({:relative, factor, opts}) do
    to_config(
      fn nil, %ResponseMeta{duration: duration} -> {round(duration / 1_000 * factor), nil} end,
      nil,
      opts
    )
  end

  @spec to_config(fun :: limiter(), initial_state :: term(), opts :: Keyword.t()) ::
          {:ok, state()}
  def to_config(fun, initial_state, opts \\ []) do
    # TODO validate delays: must be integers
    # max_delay > min_delay, etc.
    config = %{
      limiter: fun,
      internal_state: initial_state,
      current_delay: 0,
      min_delay: Keyword.get(opts, :min_delay, @min_delay),
      max_delay: Keyword.get(opts, :max_delay, @max_delay)
    }

    {:ok, config}
  end
end
