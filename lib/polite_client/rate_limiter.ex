defmodule PoliteClient.RateLimiter do
  @moduledoc """
  Functionality related to rate limiting.

  In order to avoid overwhelming a remote host, the PoliteClient will introduce a delay between requests
  executed with the same partition. This delay is bounded at both extremities.

  When resuming automatically from suspension the rate limiter state is preserved: the next request will
  NOT be triggered immediately (whereas it would be on manual resume with PoliteClient.resume/1).
  """

  alias PoliteClient.ResponseMeta

  @default_min_delay 1_000
  @default_max_delay 120_000

  @typedoc "The rate limiter configuration."
  @type config :: %{
          required(:limiter) => limiter(),
          required(:initial_state) => term(),
          optional(:min_delay) => duration(),
          optional(:max_delay) => duration()
        }

  @typedoc "The rate limiter's state."
  @opaque state :: %{
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
  The (opaque) internal state that the `t:PoliteClient.RateLimiter.limiter/0` receives and
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
             {next_request_delay :: duration(), new_internal_state :: internal_state()})

  @doc "Returns a rate limiter configuration that produces a constant 1 second delay between requests."
  @spec default_config() :: config()
  def default_config() do
    {:ok, config} = config({:constant, @default_min_delay, []})
    config
  end

  @spec config({:constant | :relative, term()}) :: {:ok, config()}
  def config({tag, arg}) when is_atom(tag), do: config({tag, arg, []})

  @spec config({:constant | :relative, term(), Keyword.t()}) :: {:ok, config()}

  @doc """
  Returns a rate limiter configuration for common limiters.

  * if the first element in the tuple is `:constant`, the computed delay will always be the duration of the
      second tuple element (the `delay`).

  * if the first element in the tuple is `:relative`, the computed delay will be the duration of the
      last request (in microseconds!) multiplied by the second tuple element (the `factor`).

  In all cases, the last tuple element `opts`, is forwarded to `PoliteClient.RateLimiter.config/3`. If none is
  provided, `[]` is used as the default value.
  """
  def config({:constant, delay, opts}) do
    opts =
      opts
      |> Keyword.put_new(:min_delay, delay)
      |> Keyword.put_new(:max_delay, delay)

    config(fn nil, _response_meta -> {delay, nil} end, nil, opts)
  end

  def config({:relative, factor, opts}) do
    config(
      fn nil, %ResponseMeta{duration: duration} -> {round(duration / 1_000 * factor), nil} end,
      nil,
      opts
    )
  end

  @doc """
  Returns a rate limiter configuration.

  The configuration will use the `limiter_function` to determine (after every request) the delay to apply between requests,
  and will initialize its internal state with `initial_state`.

  The rate limiter's internal state will also be reinitialized to the value of `initial_state` when a partition
  is manually resumed.

  ### Options
  Min and max delay values of type `t:PoliteClient.RateLimiter.duration/0` can be provided as options associated
  to the `:min_delay` and `:max_delay` keys `opts`, respectively. The delay computed by `limiter_function` will then be
  clamped to ensure it is within the min and max range. The default `min_delay` is 1 second, while `max_delay` is 2 minutes.
  """
  @spec config(limiter_function :: limiter(), initial_state :: term(), opts :: Keyword.t()) ::
          {:ok, config()}
  def config(limiter_function, initial_state, opts \\ [])
      when is_function(limiter_function, 2) do
    config = %{
      limiter: limiter_function,
      initial_state: initial_state,
      min_delay: Keyword.get(opts, :min_delay),
      max_delay: Keyword.get(opts, :max_delay)
    }

    {:ok, config}
  end

  @doc false
  @spec to_state(config()) :: state()
  def to_state(%{limiter: limiter, initial_state: initial_state} = config) do
    %{
      limiter: limiter,
      initial_state: initial_state,
      internal_state: initial_state,
      current_delay: 0,
      min_delay: Map.get(config, :min_delay),
      max_delay: Map.get(config, :max_delay)
    }
    |> set_delay_boundary(:min_delay)
    |> set_delay_boundary(:max_delay)
  end

  @doc false
  @spec get_current_delay(state()) :: duration()
  def get_current_delay(%{current_delay: delay}), do: delay

  defp set_delay_boundary(state, boundary_name) when boundary_name in [:min_delay, :max_delay] do
    case Map.get(state, boundary_name) do
      delay when is_integer(delay) and delay >= 0 -> state
      _ -> Map.put(state, boundary_name, boundary_default(boundary_name))
    end
  end

  defp boundary_default(:min_delay), do: @default_min_delay
  defp boundary_default(:max_delay), do: @default_max_delay

  @doc "Validtes the configuration."
  @spec validate_config(config()) ::
          :ok
          | {:error,
             reason ::
               {:limiter, :bad_function}
               | {:min_delay | :max_delay, :bad_value}
               | {:min_delay, :greater_than_max_delay}}
  def validate_config(config) do
    with :ok <- validate_limiter(config),
         :ok <- validate_delay_range(config) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_limiter(%{limiter: limiter}) when is_function(limiter, 2), do: :ok
  defp validate_limiter(_config), do: {:error, {:limiter, :bad_function}}

  defp validate_delay_range(config) do
    with :ok <- validate_min_delay(config),
         :ok <- validate_max_delay(config) do
      case {Map.get(config, :min_delay), Map.get(config, :max_delay)} do
        {min, max} when is_integer(min) and is_integer(max) and min > max ->
          {:error, {:min_delay, :greater_than_max_delay}}

        _ ->
          :ok
      end
    else
      {:error, _} = error -> error
    end
  end

  def validate_min_delay(%{min_delay: delay}) do
    if optional_delay_valid?(delay) do
      :ok
    else
      {:error, {:min_delay, :bad_value}}
    end
  end

  def validate_max_delay(%{max_delay: delay}) do
    if optional_delay_valid?(delay) do
      :ok
    else
      {:error, {:max_delay, :bad_value}}
    end
  end

  defp optional_delay_valid?(nil), do: true
  defp optional_delay_valid?(delay), do: delay_valid?(delay)

  defp delay_valid?(delay) when is_integer(delay) and delay >= 0, do: true
  defp delay_valid?(_delay), do: false

  @doc """
  Updates the internal state.

  Executes the `t:PoliteClient.RateLimiter.limiter/0` function, and uses its return value to update
  the internal state.
  """
  @spec update_state!(state :: state(), response_meta :: ResponseMeta.t()) :: state()
  def update_state!(
        %{limiter: limiter, internal_state: internal_state} = state,
        %ResponseMeta{} = response_meta
      ) do
    case limiter.(internal_state, response_meta) do
      {computed_delay, new_state} ->
        if delay_valid?(computed_delay) do
          new_delay = clamp_delay(state, computed_delay)
          %{state | internal_state: new_state, current_delay: new_delay}
        else
          raise "expected rate limiter implementation to conform to `PoliteClient.RateLimiter.limiter()` " <>
                  "and return a delay conforming to `PoliteClient.RateLimiter.duration()`, but got #{
                    inspect(computed_delay)
                  }"
        end

      bad_result ->
        raise "expected rate limiter implementation to conform to `PoliteClient.RateLimiter.limiter()`, " <>
                ", but got #{inspect(bad_result)}"
    end

    {computed_delay, new_state} = limiter.(internal_state, response_meta)
    new_delay = clamp_delay(state, computed_delay)

    %{state | internal_state: new_state, current_delay: new_delay}
  end

  defp clamp_delay(%{min_delay: min, max_delay: max}, delay), do: delay |> max(min) |> min(max)

  @doc "Resets the internal state to the `t:PoliteClient.RateLimiter.internal_state/0` initially provided."
  @spec reset_internal_state(state :: state()) :: state()
  def reset_internal_state(%{initial_state: i} = state), do: %{state | internal_state: i}
end
