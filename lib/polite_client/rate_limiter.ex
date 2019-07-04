defmodule PoliteClient.RateLimiter do
  @min_delay 1_000
  @max_delay 120_000

  @type state :: %{
          limiter: limiter(),
          internal_state: term(),
          current_delay: non_neg_integer(),
          min_delay: non_neg_integer(),
          max_delay: non_neg_integer()
        }

  @type limiter() ::
          (request_duration_in_microseconds :: non_neg_integer(),
           request_result :: term(),
           internal_state :: term() ->
             {next_request_delay :: non_neg_integer(), new_internal_state :: term()})

  # TODO validations

  @spec to_config(atom()) :: {:ok, state()}
  def to_config(:default), do: to_config({:constant, @min_delay})

  @spec to_config({atom() | limiter(), term(), Keyword.t()}) :: {:ok, state()}

  def to_config({:constant, delay, opts}) do
    opts =
      opts
      |> Keyword.put_new(:min_delay, delay)
      |> Keyword.put_new(:max_delay, delay)

    to_config({fn _duration, _request_result, nil -> {delay, nil} end, nil, opts})
  end

  def to_config({:relative, factor, opts}) do
    to_config(
      {fn
         duration, _request_result, nil -> {round(duration * factor), nil}
         :unknown, :canceled, nil -> {1_000, nil}
       end, nil, opts}
    )
  end

  def to_config({fun, initial_state, opts}) do
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

  @spec to_config({atom() | limiter(), term()}) :: {:ok, state()}

  def to_config({limiter, value}) when is_atom(limiter) or is_function(limiter, 3),
    do: to_config({limiter, value, []})
end
