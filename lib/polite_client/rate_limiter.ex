defmodule PoliteClient.RateLimiter do
  alias PoliteClient.ResponseMeta

  @min_delay 1_000
  @max_delay 120_000

  @type state :: %{
          limiter: limiter(),
          initial_state: term(),
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
  def to_config(:default), do: to_config({:constant, @min_delay, []})

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
      initial_state: initial_state,
      internal_state: initial_state,
      current_delay: 0,
      min_delay: Keyword.get(opts, :min_delay, @min_delay),
      max_delay: Keyword.get(opts, :max_delay, @max_delay)
    }

    {:ok, config}
  end

  def config_valid?(%{
        limiter: limiter,
        initial_state: _,
        internal_state: _,
        current_delay: current_delay,
        min_delay: min_delay,
        max_delay: max_delay
      }) do
    is_function(limiter, 2) && delay_valid?(current_delay) && delay_valid?(min_delay) &&
      delay_valid?(max_delay)
  end

  def config_valid?(_config), do: false

  defp delay_valid?(delay) when is_integer(delay) and delay >= 0, do: true
  defp delay_valid?(_delay), do: false

  def update_state(
        %{limiter: limiter, internal_state: internal_state} = state,
        %ResponseMeta{} = response_meta
      ) do
    # TODO raise on bad return value
    {computed_delay, new_state} = limiter.(internal_state, response_meta)
    new_delay = clamp_delay(state, computed_delay)

    %{state | internal_state: new_state, current_delay: new_delay}
  end

  defp clamp_delay(%{min_delay: min, max_delay: max}, delay), do: delay |> max(min) |> min(max)

  @spec reset_internal_state(state :: state()) :: state()
  def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
end
