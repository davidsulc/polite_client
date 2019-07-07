defmodule PoliteClient.RateLimiter do
  @moduledoc """
  Functionality related to rate limiting.

  In order to avoid overwhelming a remote host, the PoliteClient will introduce a delay between requests
  executed with the same partition. This delay is bounded at both extremities.
  """

  alias PoliteClient.ResponseMeta

  @min_delay 1_000
  @max_delay 120_000

  @typedoc "The rate limiter's internal state."
  @type state :: %{
          limiter: limiter(),
          initial_state: term(),
          internal_state: term(),
          current_delay: duration(),
          min_delay: duration(),
          max_delay: duration()
        }

  @typedoc "A time duration in milliseconds."
  @type duration :: non_neg_integer()

  @typedoc """
  The (opaque) internal state that the t:PoliteClient.RateLimiter.limiter/0` receives and
  updates.
  """
  @type internal_state :: term()

  @typedoc """
  The limiter function determining what delay to apply between 2 requests made in the same partition.

  In order to avoid overwhelming hosts, requests should ideally be spaced out. The limiter function
  determines how they get spaced out.

  This function is called for every response received from a successful request performed.
  To aid in determining the delay to apply before the next request, it may make use of an internal state which is
  maintained exclusively for the limiter function.

  Every time it is called, the function will receive the current `t:PoliteClient.RateLimiter.internal_state/0`
  and the `t:PoliteClient.ResponseMeta.t/0` corresponding to the request result.

  The function should return a tuple containing the next delay to apply (of type `t:PoliteClient.RateLimiter.duration/0`)
  for the partition and the updated `t:PoliteClient.RateLimiter.internal_state/0`.

  The new `t:PoliteClient.RateLimiter.internal_state/0` value returned in the tuple will be transparently updated
  and provided to the function on the next call.
  """
  @type limiter() ::
          (internal_state :: internal_state(), response_meta :: ResponseMeta.t() ->
             {next_request_delay :: non_neg_integer(), new_internal_state :: internal_state()})

  # TODO validations

  @doc "Returns a rate limiter configuration that produces a constant 1 second delay between requests."
  @spec to_config(:default) :: {:ok, state()}
  def to_config(:default), do: to_config({:constant, @min_delay, []})

  def to_config({tag, arg}) when is_atom(tag), do: to_config({tag, arg, []})

  @spec to_config({:constant | :relative, term(), Keyword.t()}) :: {:ok, state()}

  @doc """
  Returns a rate limiter configuration for common limiters.

  * if the first element in the tuple is `:constant`, the computed delay will always be the duration of the
      second tuple element (the `delay`).

  * if the first element in the tuple is `:relative`, the computed delay will be the duration of the
      last request (in microseconds!) multiplied by the second tuple element (the `factor`).

  In all cases, the last tuple element `opts`, is forwarded to `PoliteClient.RateLimiter.to_config/3`.
  """
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

  @doc """
  Returns a rate limiter configuration.

  The configuration will use the `limiter_function` to determine (after every request) the delay to apply between requests,
  and will initialize its internal state with `initial_state`.

  Min and max delay values of type `t:PoliteClient.RateLimiter.duration/0` can be provided as options associated
  to the `:min_delay` and `:max_delay` keys, respectively. The delay computed by `limiter_function` will then be
  clamped to ensure it is within the min and max range. The default `min_delay` is 1 second, while `max_delay` is 2 minutes.

  The rate limiter's internal state will also be reinitialized to the value of `initial_state` when a partition
  is manually resumed.
  """
  @spec to_config(limiter_function :: limiter(), initial_state :: term(), opts :: Keyword.t()) ::
          {:ok, state()}
  def to_config(limiter_function, initial_state, opts \\ [])
      when is_function(limiter_function, 2) do
    # TODO validate delays: must be integers
    # max_delay > min_delay, etc.
    config = %{
      limiter: limiter_function,
      initial_state: initial_state,
      internal_state: initial_state,
      current_delay: 0,
      min_delay: Keyword.get(opts, :min_delay, @min_delay),
      max_delay: Keyword.get(opts, :max_delay, @max_delay)
    }

    {:ok, config}
  end

  @doc "Returns a boolean indicating whether the given argument is a valid internal state."
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

  @doc """
  Updates the internal state.

  Executes the `t:PoliteClient.RateLimiter.limiter/0` function, and uses its return value to update
  the internal state.
  """
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

  @doc "Resets the internal state to the `t:PoliteClient.RateLimiter.internal_state/0` initially provided."
  @spec reset_internal_state(state :: state()) :: state()
  def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
end
