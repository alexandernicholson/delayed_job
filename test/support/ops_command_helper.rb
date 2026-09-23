# frozen_string_literal: true

module OpsCommandHelper
  private
    def wait_until(timeout: 60, interval: 0.1)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until (result = yield)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep interval
      end
      result
    end

    def process_alive?(pid)
      return false unless pid.to_i > 0

      begin
        return false if Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
      end

      return false if zombie?(pid)

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def zombie?(pid)
      status = "/proc/#{pid}/status"
      File.exist?(status) && File.read(status)[/^State:\s+(\S)/, 1] == "Z"
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end

    def dead_pid
      pid = fork { exit!(0) }
      Process.wait(pid)
      pid
    end

    def write_pidfile(dir, pid, name: "delayed_job")
      FileUtils.mkdir_p(dir)
      File.join(dir, "#{name}.pid").tap { |path| File.write(path, pid.to_s) }
    end

    def read_pid(path)
      File.exist?(path) ? File.read(path).strip.to_i : nil
    end

    def kill_leftover(pid)
      return unless pid.to_i > 0

      Process.kill(:KILL, pid)
    rescue Errno::ESRCH, Errno::EPERM
    end
end
