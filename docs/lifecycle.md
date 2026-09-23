# Lifecycle and plugins

`Delayed::Lifecycle`, `Delayed::Plugin` and `Delayed::Plugins::ClearLocks` work as in delayed_job 4.2. Plugins register `before`, `after` and `around` callbacks for seven events, and the shim fires those events from the enqueue path, from `Delayed::Worker` and from Solid Queue's execution hooks.

## Events

| Event | Arguments | Fired by |
|---|---|---|
| `:enqueue` | `job` | `Delayed::Job.enqueue`, around the payload's `enqueue` hook and the store (or inline run) |
| `:execute` | `worker` | `Delayed::Worker#start`, around the whole worker run |
| `:loop` | `worker` | Every Solid Queue worker poll (`SolidQueue.around_poll`) |
| `:perform` | `worker, job` | Each attempt, around `Delayed::Worker#run` |
| `:invoke_job` | `job` | `job.invoke_job`, around the payload hooks and `perform` |
| `:error` | `worker, job` | A failed attempt, around the error handling and rescheduling |
| `:failure` | `worker, job` | Attempts exhausted or payload unloadable, around the `failure` hook and removal |

`worker` is the `Delayed::Worker` running the job: the one that called `start` or `work_off`, or `Delayed::Worker.current` (a default instance) when Solid Queue runs jobs from `bin/jobs`.

`Delayed::Lifecycle::EVENTS` lists every event with its argument names.

## Writing a plugin

```ruby
class JobTimer < Delayed::Plugin
  callbacks do |lifecycle|
    lifecycle.around(:perform) do |worker, job, &block|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      block.call(worker, job)
    ensure
      StatsD.timing("jobs.#{job.name}", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    lifecycle.before(:enqueue) { |job| job.priority ||= 5 }
    lifecycle.after(:failure) { |worker, job| Honeybadger.notify(job.error) }
  end
end

Delayed::Worker.plugins << JobTimer
```

- `callbacks { |lifecycle| ... }` stores the block. Instantiating the plugin (`JobTimer.new`) calls it with `Delayed::Worker.lifecycle`.
- `Delayed::Worker.setup_lifecycle` builds a fresh lifecycle and instantiates every class in `Delayed::Worker.plugins`. It runs when the lifecycle is first used and on every `Delayed::Worker.new`, so add plugins before creating workers. Plugins are registered once per lifecycle.
- `before` and `after` callbacks receive the event arguments. `after` callbacks do not run when the block raises.
- `around` callbacks receive the arguments and a block. Call `block.call(*args)` to continue; several around callbacks nest in registration order, the first outermost.
- `run_callbacks(event, *args) { ... }` returns the block's value. The wrong number of arguments raises `ArgumentError, "Callback execute expects 1 parameter(s): worker"`; an unknown event raises `Delayed::InvalidCallback, "Unknown callback event: bogus"`; an unknown callback type raises `Delayed::InvalidCallback, "Invalid callback type: sideways"`.

`Delayed::Callback` is the per-event chain behind the lifecycle, with `add(type, &block)` and `execute(*args, &block)`.

## `Delayed::Plugins::ClearLocks`

The default plugin. It wraps `:execute` and, when the worker stops, calls `Delayed::Job.clear_locks!(worker.name)` if the backend provides it. On Solid Queue, a stopping worker deregisters and its unstarted claims go back to ready, so jobs are never left locked.

## Solid Queue hooks

The shim registers one `SolidQueue.around_poll` hook to fire `:loop`, at load time and again from `setup_lifecycle` if `SolidQueue::ExecutionHooks.clear` removed it. `:perform`, `:invoke_job`, `:error` and `:failure` run inside the job's own `perform`, so they work in every Solid Queue worker (`bin/jobs`, `Delayed::Worker#start`, `work_off` and `SolidQueue.work_off`). Solid Queue's `around_claim`, `around_perform`, `on_failure` and `around_poll` hooks stay available for app code alongside plugins.
